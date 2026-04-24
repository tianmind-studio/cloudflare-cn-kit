# lib/dns.sh
# shellcheck shell=bash

# Resolve fqdn -> zone_id by walking up the parent domain.
_cfcn_zone_for_fqdn() {
  local fqdn="$1"
  local rest="$fqdn"
  while [[ "$rest" == *.*.* ]]; do
    rest="${rest#*.}"
    local id
    id=$(cfcn_api GET "/zones?name=$rest" 2>/dev/null | jq -r '.[0].id // empty')
    if [[ -n "$id" ]]; then
      printf '%s|%s' "$rest" "$id"
      return 0
    fi
  done
  # Try the full thing too.
  local id
  id=$(cfcn_api GET "/zones?name=$fqdn" 2>/dev/null | jq -r '.[0].id // empty')
  if [[ -n "$id" ]]; then
    printf '%s|%s' "$fqdn" "$id"
    return 0
  fi
  return 1
}

cfcn_dns() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    list|ls)
      local zname="${1:-}"
      if [[ -z "$zname" ]]; then
        # List across all accessible zones (can be a lot — user opt-in).
        local zones
        zones=$(cfcn_api GET "/zones?per_page=50" | jq -r '.[] | [.name, .id] | @tsv')
        printf '%-40s %-16s %-6s %s\n' NAME CONTENT TYPE PROXIED
        while IFS=$'\t' read -r zn zid; do
          cfcn_api GET "/zones/$zid/dns_records?per_page=100" \
            | jq -r '.[] | [.name, .content, .type, .proxied] | @tsv' \
            | awk -F '\t' '{printf "%-40s %-16s %-6s %s\n", $1, $2, $3, $4}'
        done <<< "$zones"
        return 0
      fi
      local id; id=$(cfcn_zone_id "$zname") || return 1
      if [[ "${CFCN_JSON:-0}" == "1" ]]; then
        cfcn_api GET "/zones/$id/dns_records?per_page=200"
        return 0
      fi
      printf '%-40s %-16s %-6s %s\n' NAME CONTENT TYPE PROXIED
      cfcn_api GET "/zones/$id/dns_records?per_page=200" \
        | jq -r '.[] | [.name, .content, .type, .proxied] | @tsv' \
        | awk -F '\t' '{printf "%-40s %-16s %-6s %s\n", $1, $2, $3, $4}'
      ;;
    add|upsert)
      local fqdn="${1:?usage: dns add <fqdn> <ip> [--proxied]}"
      local ip="${2:?usage: dns add <fqdn> <ip> [--proxied]}"
      local proxied=false
      [[ "${3:-}" == "--proxied" ]] && proxied=true
      local z; z=$(_cfcn_zone_for_fqdn "$fqdn") || { cfcn_err "no zone found for $fqdn"; return 1; }
      local zname="${z%|*}" zid="${z#*|}"
      cfcn_info "zone: $zname ($zid)"

      local existing
      existing=$(cfcn_api GET "/zones/$zid/dns_records?type=A&name=$fqdn" | jq -r '.[0].id // empty')

      if [[ "${CFCN_DRY_RUN:-0}" == "1" ]]; then
        cfcn_info "would ${existing:+update}${existing:-create} A $fqdn -> $ip (proxied=$proxied)"
        return 0
      fi

      if [[ -z "$existing" ]]; then
        cfcn_api POST "/zones/$zid/dns_records" \
          "$(jq -n --arg n "$fqdn" --arg ip "$ip" --argjson p "$proxied" \
              '{type:"A", name:$n, content:$ip, ttl:1, proxied:$p}')" >/dev/null
        cfcn_ok "created: $fqdn -> $ip"
      else
        cfcn_api PATCH "/zones/$zid/dns_records/$existing" \
          "$(jq -n --arg ip "$ip" --argjson p "$proxied" '{content:$ip, proxied:$p}')" >/dev/null
        cfcn_ok "updated: $fqdn -> $ip"
      fi
      ;;
    del|rm)
      local fqdn="${1:?usage: dns del <fqdn>}"
      local z; z=$(_cfcn_zone_for_fqdn "$fqdn") || { cfcn_err "no zone found for $fqdn"; return 1; }
      local zid="${z#*|}"
      local rid
      rid=$(cfcn_api GET "/zones/$zid/dns_records?name=$fqdn" | jq -r '.[0].id // empty')
      [[ -z "$rid" ]] && { cfcn_warn "no record for $fqdn"; return 0; }
      if [[ "${CFCN_DRY_RUN:-0}" == "1" ]]; then
        cfcn_info "would delete $fqdn ($rid)"; return 0
      fi
      cfcn_api DELETE "/zones/$zid/dns_records/$rid" >/dev/null
      cfcn_ok "deleted: $fqdn"
      ;;
    wildcard)
      local domain="${1:?usage: dns wildcard <domain> <ip>}"
      local ip="${2:?usage: dns wildcard <domain> <ip>}"
      cfcn_dns add "*.$domain" "$ip"
      ;;
    diff)
      # Compare a YAML bulk file against live Cloudflare state. Shows what
      # 'dns bulk <yaml>' would change, without touching anything.
      #
      # Legend:
      #   + create  (in YAML, not in CF)
      #   ~ update  (in YAML, differs from CF)
      #   = same    (in YAML, matches CF)
      #   . unmanaged (in CF but not in YAML; bulk won't touch)
      local file="${1:?usage: dns diff <yaml-file>}"
      [[ ! -f "$file" ]] && { cfcn_err "not found: $file"; return 1; }

      # Extract records from YAML using the same parser shape as 'bulk'.
      local yaml_records
      yaml_records=$(awk '
        BEGIN { cur = "" }
        /^[[:space:]]*-[[:space:]]+name:/ {
          if (cur != "") print cur
          line = $0
          sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", line)
          cur = "name=" line
          next
        }
        /^[[:space:]]+ip:/ {
          line = $0
          sub(/^[[:space:]]+ip:[[:space:]]*/, "", line)
          cur = cur "|ip=" line
          next
        }
        /^[[:space:]]+proxied:/ {
          line = $0
          sub(/^[[:space:]]+proxied:[[:space:]]*/, "", line)
          cur = cur "|proxied=" line
          next
        }
        END { if (cur != "") print cur }
      ' "$file")
      [[ -z "$yaml_records" ]] && { cfcn_warn "no A records in $file"; return 0; }

      # Determine which zone(s) the YAML covers (first record wins; warn if
      # a single file mixes zones — dns bulk supports it but diff gets noisy).
      local first_name
      first_name=$(printf '%s\n' "$yaml_records" | head -1 | tr '|' '\n' | awk -F= '/^name=/ {print $2}')
      local z; z=$(_cfcn_zone_for_fqdn "$first_name") || { cfcn_err "no zone found for $first_name"; return 1; }
      local zname="${z%|*}" zid="${z#*|}"
      cfcn_info "zone: $zname"

      # Snapshot live A records into a tsv: name<TAB>ip<TAB>proxied
      local live_tsv
      live_tsv=$(cfcn_api GET "/zones/$zid/dns_records?type=A&per_page=200" \
        | jq -r '.[] | [.name, .content, (.proxied|tostring)] | @tsv')

      # Track which live records we've matched so we can list the rest.
      local -A seen_names=()
      local adds=0 updates=0 sames=0
      local yaml_rec
      while IFS= read -r yaml_rec; do
        local name ip proxied="false"
        name=$(printf '%s' "$yaml_rec" | tr '|' '\n' | awk -F= '/^name=/ {print $2}')
        ip=$(printf '%s' "$yaml_rec" | tr '|' '\n' | awk -F= '/^ip=/ {print $2}')
        if printf '%s' "$yaml_rec" | grep -q 'proxied=true'; then proxied="true"; fi
        [[ -z "$name" || -z "$ip" ]] && continue

        # Lookup this name in live_tsv.
        local live_line live_ip live_proxied
        live_line=$(printf '%s\n' "$live_tsv" | awk -F '\t' -v n="$name" '$1 == n {print; exit}')
        if [[ -z "$live_line" ]]; then
          printf '%s+%s %s  %s (proxied=%s)\n' "$C_GREEN" "$C_RESET" "$name" "$ip" "$proxied"
          adds=$((adds+1))
          continue
        fi
        seen_names[$name]=1
        live_ip=$(printf '%s' "$live_line" | awk -F '\t' '{print $2}')
        live_proxied=$(printf '%s' "$live_line" | awk -F '\t' '{print $3}')

        if [[ "$live_ip" == "$ip" && "$live_proxied" == "$proxied" ]]; then
          printf '%s=%s %s  %s (proxied=%s)\n' "$C_DIM" "$C_RESET" "$name" "$ip" "$proxied"
          sames=$((sames+1))
        else
          printf '%s~%s %s  %s (proxied=%s)  ->  %s (proxied=%s)\n' \
            "$C_YELLOW" "$C_RESET" "$name" "$live_ip" "$live_proxied" "$ip" "$proxied"
          updates=$((updates+1))
        fi
      done <<< "$yaml_records"

      # List live A records not covered by the YAML — informational only.
      local unmanaged=0
      while IFS= read -r live_line; do
        [[ -z "$live_line" ]] && continue
        local live_name live_ip live_proxied
        live_name=$(printf '%s' "$live_line" | awk -F '\t' '{print $1}')
        live_ip=$(printf '%s' "$live_line" | awk -F '\t' '{print $2}')
        live_proxied=$(printf '%s' "$live_line" | awk -F '\t' '{print $3}')
        [[ -n "${seen_names[$live_name]:-}" ]] && continue
        printf '%s.%s %s  %s (proxied=%s)  %s(unmanaged — dns bulk will not touch)%s\n' \
          "$C_DIM" "$C_RESET" "$live_name" "$live_ip" "$live_proxied" "$C_DIM" "$C_RESET"
        unmanaged=$((unmanaged+1))
      done <<< "$live_tsv"

      printf '\n'
      printf 'summary: %d create, %d update, %d unchanged, %d unmanaged\n' \
        "$adds" "$updates" "$sames" "$unmanaged"
      ;;
    export)
      # Dump a zone's DNS records to YAML compatible with 'dns bulk'.
      # Useful for pre-migration snapshots, GitOps, or review before bulk edits.
      local zname="${1:?usage: dns export <zone> [--out <file>]}"
      shift
      local out=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --out) out="$2"; shift 2 ;;
          *) shift ;;
        esac
      done

      local zid
      zid=$(cfcn_zone_id "$zname") || return 1

      local dest
      dest="${out:-/dev/stdout}"
      {
        printf '# Exported from Cloudflare zone: %s\n' "$zname"
        printf '# Generated: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '# Note: only A/AAAA/CNAME records are included in bulk-compatible form.\n'
        printf '#       MX/TXT/SRV are preserved as comments for reference.\n'
        printf 'records:\n'
        cfcn_api GET "/zones/$zid/dns_records?per_page=200" \
          | jq -r '.[] | @json' \
          | while IFS= read -r record; do
              local name type content proxied
              name=$(jq -r '.name' <<< "$record")
              type=$(jq -r '.type' <<< "$record")
              content=$(jq -r '.content' <<< "$record")
              proxied=$(jq -r '.proxied' <<< "$record")
              case "$type" in
                A)
                  printf '  - name: %s\n' "$name"
                  printf '    ip: %s\n' "$content"
                  [[ "$proxied" == "true" ]] && printf '    proxied: true\n'
                  ;;
                AAAA|CNAME|MX|TXT|SRV|NS|CAA)
                  # Preserved as a comment so you don't lose them silently.
                  printf '  # %s %s %s (proxied=%s)\n' "$type" "$name" "$content" "$proxied"
                  ;;
              esac
            done
      } > "$dest"

      if [[ -n "$out" ]]; then
        cfcn_ok "exported $zname -> $out"
      fi
      ;;
    bulk)
      local file="${1:?usage: dns bulk <yaml-file>}"
      [[ ! -f "$file" ]] && { cfcn_err "not found: $file"; return 1; }
      # Each record line: "- name: fqdn / ip: 1.2.3.4 / proxied: true"
      # We parse a flat schema with awk.
      local records
      records=$(awk '
        BEGIN { cur = "" }
        /^[[:space:]]*-[[:space:]]+name:/ {
          if (cur != "") print cur
          line = $0
          sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", line)
          cur = "name=" line
          next
        }
        /^[[:space:]]+ip:/ {
          line = $0
          sub(/^[[:space:]]+ip:[[:space:]]*/, "", line)
          cur = cur "|ip=" line
          next
        }
        /^[[:space:]]+proxied:/ {
          line = $0
          sub(/^[[:space:]]+proxied:[[:space:]]*/, "", line)
          cur = cur "|proxied=" line
          next
        }
        END { if (cur != "") print cur }
      ' "$file")

      [[ -z "$records" ]] && { cfcn_warn "no records in $file"; return 0; }
      while IFS= read -r rec; do
        local name ip proxied="false"
        name=$(printf '%s' "$rec" | tr '|' '\n' | awk -F= '/^name=/ {print $2}')
        ip=$(printf '%s' "$rec" | tr '|' '\n' | awk -F= '/^ip=/ {print $2}')
        if printf '%s' "$rec" | grep -q 'proxied=true'; then proxied="true"; fi

        if [[ -z "$name" || -z "$ip" ]]; then
          cfcn_warn "skipping malformed record: $rec"
          continue
        fi
        if [[ "$proxied" == "true" ]]; then
          cfcn_dns add "$name" "$ip" --proxied
        else
          cfcn_dns add "$name" "$ip"
        fi
      done <<< "$records"
      ;;
    help|--help|"")
      cat <<'EOF'
cfcn dns — DNS record operations.

  dns list [zone]             List records (all zones if no zone given).
  dns add <fqdn> <ip> [--proxied]
                              Create or update an A record; zone is inferred.
  dns del <fqdn>              Delete an A record.
  dns bulk <yaml>             Apply multiple records from a YAML file.
  dns diff <yaml>             Preview what 'dns bulk <yaml>' would change.
  dns wildcard <domain> <ip>  Create *.domain A record.
  dns export <zone> [--out f] Dump a zone to bulk-compatible YAML (stdout or file).
EOF
      ;;
    *) cfcn_err "unknown dns subcommand: $sub"; return 2 ;;
  esac
}
