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
  dns wildcard <domain> <ip>  Create *.domain A record.
EOF
      ;;
    *) cfcn_err "unknown dns subcommand: $sub"; return 2 ;;
  esac
}
