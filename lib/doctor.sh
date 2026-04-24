# lib/doctor.sh
# shellcheck shell=bash

cfcn_doctor() {
  cfcn_step "Local tools"
  local ok=1
  for bin in curl jq awk; do
    if command -v "$bin" >/dev/null 2>&1; then
      cfcn_ok "$bin: $(command -v "$bin")"
    else
      cfcn_err "$bin not found"; ok=0
    fi
  done

  cfcn_step "API token"
  if [[ -n "${CFCN_TOKEN:-}" ]]; then
    cfcn_ok "CFCN_TOKEN is set"
  elif [[ -n "${CF_API_TOKEN:-}" ]]; then
    cfcn_ok "CF_API_TOKEN is set (fallback)"
    CFCN_TOKEN="$CF_API_TOKEN"
  else
    cfcn_err "no token set. Set CFCN_TOKEN or CF_API_TOKEN."
    ok=0
  fi

  if [[ -n "${CFCN_TOKEN:-}" ]]; then
    cfcn_step "Token verification"
    local resp http_code
    resp=$(curl -sS -w '\n%{http_code}' \
      -H "Authorization: Bearer $CFCN_TOKEN" \
      https://api.cloudflare.com/client/v4/user/tokens/verify)
    http_code="${resp##*$'\n'}"
    resp="${resp%$'\n'*}"
    if [[ "$http_code" == "200" ]]; then
      local status
      status=$(printf '%s' "$resp" | jq -r '.result.status')
      cfcn_ok "token status: $status"
    else
      cfcn_err "verify failed (HTTP $http_code)"
      ok=0
    fi
  fi

  [[ $ok -eq 1 ]]
}
