# lib/ssl.sh — SSL mode + the famous Flexible-SSL redirect-loop diagnostic.
# shellcheck shell=bash

cfcn_ssl() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    diag)
      local domain="${1:?usage: ssl diag <domain>}"
      _cfcn_ssl_diag "$domain"
      ;;
    mode)
      # Alias to 'zone ssl'.
      # shellcheck source=lib/zone.sh
      source "$CFCN_LIB/zone.sh"
      cfcn_zone ssl "$@"
      ;;
    hsts)
      local name="${1:?usage: ssl hsts <zone> [on|off]}"
      local on="${2:-}"
      local id; id=$(cfcn_zone_id "$name") || return 1
      if [[ -z "$on" ]]; then
        cfcn_api GET "/zones/$id/settings/security_header" \
          | jq -r '.value.strict_transport_security.enabled'
        return 0
      fi
      local enabled=false
      [[ "$on" == "on" || "$on" == "true" ]] && enabled=true
      if [[ "${CFCN_DRY_RUN:-0}" == "1" ]]; then
        cfcn_info "would set HSTS: $name -> $enabled"; return 0
      fi
      cfcn_api PATCH "/zones/$id/settings/security_header" \
        "$(jq -n --argjson e "$enabled" \
            '{value:{strict_transport_security:{enabled:$e, max_age:31536000, include_subdomains:false, preload:false, nosniff:true}}}')" >/dev/null
      cfcn_ok "$name: HSTS -> $enabled"
      ;;
    help|--help|"")
      cat <<'EOF'
cfcn ssl — TLS/HTTPS operations.

  ssl diag <domain>        Diagnose redirect loops and Flexible-SSL traps.
  ssl mode <zone> [mode]   Read or set SSL mode (off|flexible|full|strict).
  ssl hsts <zone> [on|off] Toggle HSTS.
EOF
      ;;
    *) cfcn_err "unknown ssl subcommand: $sub"; return 2 ;;
  esac
}

# The diagnostic that catches the #1 "my site is broken after moving to CF"
# bug from China-region ops: Flexible SSL + origin-side HTTPS -> infinite
# loop / Cloudfront 403 / plain 5xx depending on origin.
_cfcn_ssl_diag() {
  local domain="$1"
  cfcn_step "SSL diagnosis: $domain"

  # Step 1: what SSL mode is the zone in?
  local z
  z=$(_cfcn_zone_for_fqdn "$domain" 2>/dev/null || true)
  local zname="" zid=""
  if [[ -n "$z" ]]; then
    zname="${z%|*}"
    zid="${z#*|}"
    cfcn_info "zone:      $zname"
  else
    cfcn_warn "zone lookup failed (domain may not be on your Cloudflare account)"
  fi

  local ssl_mode=""
  if [[ -n "$zid" ]]; then
    ssl_mode=$(cfcn_api GET "/zones/$zid/settings/ssl" 2>/dev/null | jq -r '.value // "?"')
    cfcn_info "ssl mode:  $ssl_mode"
  fi

  # Step 2: is the DNS record proxied?
  local proxied="?"
  if [[ -n "$zid" ]]; then
    proxied=$(cfcn_api GET "/zones/$zid/dns_records?name=$domain" 2>/dev/null \
      | jq -r '.[0].proxied // false')
    cfcn_info "proxied:   $proxied"
  fi

  # Step 3: observe origin directly vs through CF.
  cfcn_info "probing origin and edge..."
  local http_status https_status edge_status
  http_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -m 10 --connect-timeout 5 "http://$domain" 2>/dev/null || echo "ERR")
  https_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -m 10 --connect-timeout 5 "https://$domain" 2>/dev/null || echo "ERR")
  edge_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -m 10 --connect-timeout 5 -L --max-redirs 10 "https://$domain/" 2>/dev/null || echo "ERR")

  cfcn_info "HTTP/80:   $http_status"
  cfcn_info "HTTPS/443: $https_status"
  cfcn_info "with -L:   $edge_status  (up to 10 redirects)"

  # Step 4: known-bad patterns → specific advice.
  cfcn_step "Diagnosis"
  local hit=0

  if [[ "$ssl_mode" == "flexible" && "$proxied" == "true" ]]; then
    hit=1
    cfcn_warn "SSL mode is 'flexible' AND DNS is proxied."
    cfcn_tip "This is the classic Flexible-SSL redirect loop setup."
    cfcn_tip "  - CF talks to your origin over HTTP, but your origin (nginx)"
    cfcn_tip "    redirects HTTP to HTTPS. CF receives the 301, redirects the"
    cfcn_tip "    client, client loops."
    cfcn_tip "  - Fix option A: switch zone to SSL mode 'full' and install a"
    cfcn_tip "    cert on origin (certbot / CF Origin CA)."
    cfcn_tip "  - Fix option B: remove the 'return 301 https' from nginx and"
    cfcn_tip "    let CF 'Always Use HTTPS' do the redirect instead."
  fi

  if [[ "$http_status" =~ ^30[1278]$ && "$https_status" == "ERR" && "$ssl_mode" != "off" ]]; then
    hit=1
    cfcn_warn "origin HTTP redirects, but HTTPS is unreachable."
    cfcn_tip "Likely origin has no cert installed but nginx force-redirects to HTTPS."
    cfcn_tip "  - If using CF Flexible: DON'T redirect on origin. Let CF redirect."
    cfcn_tip "  - If using CF Full: install a cert on origin (certbot --nginx)."
  fi

  if [[ "$edge_status" == "ERR" || "$edge_status" == "000" ]]; then
    hit=1
    cfcn_warn "even following redirects from a fresh client: unreachable."
    cfcn_tip "Possible: DNS not propagated, firewall blocking 443, CF zone paused."
  fi

  # Common: CN ISP returning an empty reply on 443 despite proxied=true.
  # Could mean Cloudflare IP ranges are being RST'd locally.
  if [[ "$https_status" == "000" && "$proxied" == "true" ]]; then
    hit=1
    cfcn_warn "https returned 000 while going through CF's proxy."
    cfcn_tip "If you're testing from inside mainland China, try again from a"
    cfcn_tip "different network. Some CN ISPs RST the connection to specific"
    cfcn_tip "CF IP ranges, producing exactly this failure mode."
  fi

  if [[ $hit -eq 0 ]]; then
    cfcn_ok "no known bad pattern detected."
    cfcn_info "if you still have issues, run 'cfcn ssl diag --verbose' for raw probes."
  fi
}
