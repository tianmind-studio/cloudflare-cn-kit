# lib/zone.sh
# shellcheck shell=bash

cfcn_zone() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    list|ls)
      local data
      data=$(cfcn_api GET "/zones?per_page=50")
      if [[ "${CFCN_JSON:-0}" == "1" ]]; then printf '%s' "$data"; return 0; fi
      printf '%-32s %-18s %-8s %s\n' NAME STATUS PLAN SSL
      printf '%s' "$data" | jq -r '.[] | [.name, .status, .plan.legacy_id, .id] | @tsv' \
        | while IFS=$'\t' read -r name status plan zid; do
            local ssl
            ssl=$(cfcn_api GET "/zones/$zid/settings/ssl" | jq -r '.value // "?"')
            printf '%-32s %-18s %-8s %s\n' "$name" "$status" "$plan" "$ssl"
          done
      ;;
    show)
      local name="${1:?usage: zone show <name>}"
      local id; id=$(cfcn_zone_id "$name") || return 1
      local zone settings_ssl settings_always_use_https settings_hsts
      zone=$(cfcn_api GET "/zones/$id")
      settings_ssl=$(cfcn_api GET "/zones/$id/settings/ssl" | jq -r '.value')
      settings_always_use_https=$(cfcn_api GET "/zones/$id/settings/always_use_https" | jq -r '.value')
      settings_hsts=$(cfcn_api GET "/zones/$id/settings/security_header" | jq -r '.value.strict_transport_security.enabled // false')

      printf 'name:                %s\n' "$name"
      printf 'id:                  %s\n' "$id"
      printf 'status:              %s\n' "$(printf '%s' "$zone" | jq -r '.status')"
      printf 'plan:                %s\n' "$(printf '%s' "$zone" | jq -r '.plan.name')"
      printf 'name_servers:        %s\n' "$(printf '%s' "$zone" | jq -r '.name_servers | join(", ")')"
      printf 'ssl_mode:            %s\n' "$settings_ssl"
      printf 'always_use_https:    %s\n' "$settings_always_use_https"
      printf 'hsts_enabled:        %s\n' "$settings_hsts"
      ;;
    ssl)
      local name="${1:?usage: zone ssl <name> [off|flexible|full|strict]}"
      local mode="${2:-}"
      local id; id=$(cfcn_zone_id "$name") || return 1
      if [[ -z "$mode" ]]; then
        cfcn_api GET "/zones/$id/settings/ssl" | jq -r '.value'
        return 0
      fi
      case "$mode" in off|flexible|full|strict) ;;
        *) cfcn_err "bad mode: $mode (off|flexible|full|strict)"; return 2 ;;
      esac
      if [[ "${CFCN_DRY_RUN:-0}" == "1" ]]; then
        cfcn_info "would set SSL mode: $name -> $mode"; return 0
      fi
      cfcn_api PATCH "/zones/$id/settings/ssl" \
        "$(jq -n --arg v "$mode" '{value:$v}')" >/dev/null
      cfcn_ok "$name: SSL mode -> $mode"
      ;;
    purge)
      local name="${1:?usage: zone purge <name> [host]}"
      local host="${2:-}"
      local id; id=$(cfcn_zone_id "$name") || return 1
      local body='{"purge_everything":true}'
      if [[ -n "$host" ]]; then
        body=$(jq -n --arg h "$host" '{hosts:[$h]}')
      fi
      if [[ "${CFCN_DRY_RUN:-0}" == "1" ]]; then
        cfcn_info "would purge: $name ${host:-(everything)}"
        return 0
      fi
      cfcn_api POST "/zones/$id/purge_cache" "$body" >/dev/null
      cfcn_ok "purged: $name ${host:-(everything)}"
      ;;
    help|--help|"")
      cat <<'EOF'
cfcn zone — zone-level operations.

  zone list                 List all zones.
  zone show <name>          Detail view (SSL mode, HSTS, name servers).
  zone ssl <name> [mode]    Read or set SSL mode.
  zone purge <name> [host]  Purge cache (everything by default).
EOF
      ;;
    *) cfcn_err "unknown zone subcommand: $sub"; return 2 ;;
  esac
}
