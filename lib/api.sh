# lib/api.sh — Cloudflare API wrapper with error-unwrapping.
# shellcheck shell=bash

: "${CFCN_TOKEN:=${CF_API_TOKEN:-}}"

_cfcn_require_token() {
  if [[ -z "${CFCN_TOKEN:-}" ]]; then
    cfcn_err "no API token. Set CFCN_TOKEN (or CF_API_TOKEN)."
    cfcn_info "create one at https://dash.cloudflare.com/profile/api-tokens"
    cfcn_info "minimum scopes: Zone:Zone:Read, Zone:DNS:Edit"
    return 1
  fi
}

# Low-level call. Echoes the raw `result` JSON. Exits non-zero on API error.
cfcn_api() {
  _cfcn_require_token || return 1
  local method="$1" path="$2" body="${3:-}"
  local url="https://api.cloudflare.com/client/v4${path}"

  local response http_code
  if [[ -n "$body" ]]; then
    response=$(curl -sS -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $CFCN_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body" "$url")
  else
    response=$(curl -sS -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $CFCN_TOKEN" \
      "$url")
  fi
  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"

  local ok
  ok=$(printf '%s' "$response" | jq -r '.success // false' 2>/dev/null || echo false)
  if [[ "$ok" != "true" ]]; then
    local msg
    msg=$(printf '%s' "$response" | jq -r '.errors[]?.message' 2>/dev/null | paste -sd '; ' - || true)
    [[ -z "$msg" ]] && msg="HTTP $http_code"
    cfcn_err "Cloudflare API: $msg"
    return 1
  fi
  # Print the result — could be an object or an array.
  printf '%s' "$response" | jq '.result'
}

# Resolve a zone name -> id. Exits non-zero if not found.
cfcn_zone_id() {
  local name="$1"
  local id
  id=$(cfcn_api GET "/zones?name=$name" | jq -r '.[0].id // empty')
  if [[ -z "$id" ]]; then
    cfcn_err "zone not found (or no access): $name"
    return 1
  fi
  printf '%s' "$id"
}
