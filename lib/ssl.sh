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
  local http_status https_status edge_status https_headers curl_err
  http_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -m 10 --connect-timeout 5 "http://$domain" 2>/dev/null || echo "ERR")
  # Capture headers AND code; also capture stderr for a later curl_err parse.
  local headers_file; headers_file=$(mktemp)
  https_status=$(curl -sS -o /dev/null -D "$headers_file" -w '%{http_code}' \
    -m 10 --connect-timeout 5 "https://$domain" 2>"${headers_file}.err" || echo "ERR")
  https_headers=$(cat "$headers_file")
  curl_err=$(cat "${headers_file}.err" 2>/dev/null)
  rm -f "$headers_file" "${headers_file}.err"
  edge_status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -m 10 --connect-timeout 5 -L --max-redirs 10 "https://$domain/" 2>/dev/null || echo "ERR")

  cfcn_info "HTTP/80:   $http_status"
  cfcn_info "HTTPS/443: $https_status"
  cfcn_info "with -L:   $edge_status  (up to 10 redirects)"

  # Extract HSTS header if present.
  local hsts_header
  hsts_header=$(printf '%s\n' "$https_headers" \
    | awk 'tolower($1) == "strict-transport-security:" {sub(/^[^:]+:[[:space:]]*/, ""); print; exit}' \
    | tr -d '\r')
  [[ -n "$hsts_header" ]] && cfcn_info "HSTS:      $hsts_header"

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

  # Pattern: CN ISP returning an empty reply on 443 despite proxied=true.
  # Refined — distinguish RST ("Connection reset") from timeout ("Operation timed
  # out") from handshake failure so the advice can be specific.
  if [[ "$https_status" == "000" && "$proxied" == "true" ]]; then
    hit=1
    if printf '%s' "$curl_err" | grep -qiE 'connection reset|recv failure|rst'; then
      cfcn_warn "https returned 000 with connection reset, going through CF's proxy."
      cfcn_tip "This is the classic CN-ISP RST signature against specific CF IP ranges."
      cfcn_tip "  - Confirm: test from a different network (different ISP or mobile data)."
      cfcn_tip "  - Confirm: 'curl -v https://<domain> --resolve <domain>:443:<different-CF-IP>'"
      cfcn_tip "    If one CF IP works and another doesn't, the ISP is pattern-blocking."
      cfcn_tip "  - Mitigations: disable CF proxy (grey cloud) and serve directly from"
      cfcn_tip "    origin, OR move the site to a zone that proxies through different CF IPs."
    elif printf '%s' "$curl_err" | grep -qiE 'timed out|timeout'; then
      cfcn_warn "https timed out through CF's proxy (not a reset)."
      cfcn_tip "Likely DNS still propagating, or origin behind the CF IP is unresponsive."
      cfcn_tip "  - Wait 5-15 minutes and retry. If you just flipped the proxied switch,"
      cfcn_tip "    propagation can take longer than CF's claimed TTL."
    elif printf '%s' "$curl_err" | grep -qiE 'ssl|handshake|certificate'; then
      cfcn_warn "https failed TLS handshake through CF's proxy."
      cfcn_tip "This is rare through CF (they terminate TLS at the edge)."
      cfcn_tip "  - Check if your zone is paused: 'cfcn zone show $zname'"
      cfcn_tip "  - Check if you have a dedicated/custom cert that's expired on CF."
    else
      cfcn_warn "https returned 000 while going through CF's proxy. Cause not obvious."
      cfcn_tip "If you're on a CN network, try a different ISP to rule out RST."
      cfcn_tip "Raw curl error: ${curl_err:-(empty)}"
    fi
  fi

  # Pattern: CF 525 (SSL handshake failed with origin) or 526 (invalid origin cert).
  # Happens in Full/Full(strict) mode when origin cert expired, misconfigured, or
  # doesn't exist. The 525/526 is emitted by CF itself, not by the origin.
  if [[ "$https_status" == "525" || "$https_status" == "526" ]]; then
    hit=1
    cfcn_warn "CF returned $https_status: can't establish a valid TLS session to your origin."
    cfcn_tip "SSL mode is '$ssl_mode' which requires a valid cert on origin."
    cfcn_tip "  - 525 = handshake failed (cert missing, nginx not listening on 443,"
    cfcn_tip "          or TLS version mismatch between CF and origin)."
    cfcn_tip "  - 526 = origin cert invalid (self-signed in strict mode, expired,"
    cfcn_tip "          or name mismatch)."
    cfcn_tip "  - Fix: ssh to origin, run 'certbot renew --nginx' or reinstall cert."
    cfcn_tip "  - Workaround (not strict): switch to mode 'full' (non-strict) — unsafe,"
    cfcn_tip "    but useful briefly while you fix the cert."
  fi

  # Pattern: HSTS preload directive present. This is dangerous enough to flag
  # every time — operators forget how hard it is to remove once the domain is
  # actually submitted to the browser preload list.
  if [[ -n "$hsts_header" ]] && printf '%s' "$hsts_header" | grep -qi 'preload'; then
    hit=1
    cfcn_warn "HSTS response header includes 'preload' directive."
    cfcn_tip "Intent: submit the domain to https://hstspreload.org/ for inclusion"
    cfcn_tip "in Chrome/Firefox/Safari preload lists."
    cfcn_tip "Cost: once in the preload list, even removing the header is not enough"
    cfcn_tip "for ~months until browsers refresh their baked-in list. A site that"
    cfcn_tip "ever serves HTTPS-breakage content (e.g. dev subdomain without a cert,"
    cfcn_tip "or an acquired subsite without SSL) will be broken for real users."
    cfcn_tip "  - Only enable 'preload' if you are certain the domain AND every"
    cfcn_tip "    subdomain (if includeSubDomains is set) will always have valid HTTPS."
    cfcn_tip "  - To remove: 'cfcn ssl hsts $zname off' + submit removal at"
    cfcn_tip "    https://hstspreload.org/removal/ + wait months."
  fi

  # Pattern: HSTS max-age 0 — browsers will forget HSTS in 0s.
  # Sometimes this is intentional (removing HSTS) but usually a config mistake.
  if [[ -n "$hsts_header" ]] && printf '%s' "$hsts_header" | grep -qE 'max-age=[[:space:]]*0([^0-9]|$)'; then
    hit=1
    cfcn_warn "HSTS max-age is 0 — effectively disables HSTS."
    cfcn_tip "Is this intentional (you're removing HSTS)? If not, a typo."
    cfcn_tip "Typical production value: max-age=31536000 (1 year)."
  fi

  if [[ $hit -eq 0 ]]; then
    cfcn_ok "no known bad pattern detected."
    cfcn_info "if you still have issues, the logs you want are:"
    cfcn_info "  - CF dashboard → Overview → Recent events"
    cfcn_info "  - origin: /var/log/nginx/error.log"
  fi
}
