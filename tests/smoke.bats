#!/usr/bin/env bats
#
# Smoke tests for cfcn. No Cloudflare API token is assumed on the CI
# runner, so tests that would hit the API are either skipped or expected
# to fail with a specific "no token" message.

setup() {
  CFCN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CFCN_BIN="$CFCN_ROOT/bin/cfcn"
  TMP="$(mktemp -d)"
  cd "$TMP"

  # Ensure neither CFCN_TOKEN nor CF_API_TOKEN leak into the test env —
  # the whole point is to verify graceful failure without a token.
  unset CFCN_TOKEN
  unset CF_API_TOKEN
}

teardown() {
  [[ -n "${TMP:-}" && -d "${TMP:-}" ]] && rm -rf "$TMP"
}

assert_output_contains() {
  local needle="$1"
  if [[ "$output" != *"$needle"* ]]; then
    printf 'expected output to contain: %s\n--- output ---\n%s\n' "$needle" "$output" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local needle="$1"
  if [[ "$output" == *"$needle"* ]]; then
    printf 'expected output not to contain: %s\n--- output ---\n%s\n' "$needle" "$output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Top-level
# ---------------------------------------------------------------------------

@test "version prints a semver-ish string" {
  run "$CFCN_BIN" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ cfcn[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "--version alias works" {
  run "$CFCN_BIN" --version
  [ "$status" -eq 0 ]
}

@test "help lists every top-level command" {
  run "$CFCN_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"zone"*    ]]
  [[ "$output" == *"dns"*     ]]
  [[ "$output" == *"ssl"*     ]]
  [[ "$output" == *"cn"*      ]]
  [[ "$output" == *"doctor"*  ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--json"*    ]]
}

@test "unknown command exits non-zero" {
  run "$CFCN_BIN" wildly-not-a-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

# ---------------------------------------------------------------------------
# Subcommand dispatch — help should work without a token
# ---------------------------------------------------------------------------

@test "zone help lists zone subcommands" {
  run "$CFCN_BIN" zone help
  [ "$status" -eq 0 ]
  [[ "$output" == *"list"*   ]]
  [[ "$output" == *"show"*   ]]
  [[ "$output" == *"ssl"*    ]]
  [[ "$output" == *"purge"*  ]]
}

@test "dns help lists dns subcommands" {
  run "$CFCN_BIN" dns help
  [ "$status" -eq 0 ]
  [[ "$output" == *"add"*       ]]
  [[ "$output" == *"del"*       ]]
  [[ "$output" == *"bulk"*      ]]
  [[ "$output" == *"diff"*      ]]
  [[ "$output" == *"wildcard"*  ]]
  [[ "$output" == *"export"*    ]]
}

@test "ssl help lists ssl subcommands" {
  run "$CFCN_BIN" ssl help
  [ "$status" -eq 0 ]
  [[ "$output" == *"diag"*  ]]
  [[ "$output" == *"mode"*  ]]
  [[ "$output" == *"hsts"*  ]]
}

@test "cn help lists cn subcommands" {
  run "$CFCN_BIN" cn help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ping"*   ]]
  [[ "$output" == *"trace"*  ]]
}

@test "unknown zone subcommand exits non-zero" {
  run "$CFCN_BIN" zone blargh
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown"* ]]
}

# ---------------------------------------------------------------------------
# Graceful no-token behavior
# ---------------------------------------------------------------------------

@test "doctor reports missing token without crashing" {
  run "$CFCN_BIN" doctor
  [[ "$output" == *"token"* ]]
}

@test "zone list without a token errors with a helpful message" {
  run "$CFCN_BIN" zone list
  [ "$status" -ne 0 ]
  [[ "$output" == *"token"* ]] || [[ "$output" == *"CFCN_TOKEN"* ]]
}

# ---------------------------------------------------------------------------
# dns diff — input validation without a token
# ---------------------------------------------------------------------------

@test "dns diff with non-existent file fails cleanly" {
  run "$CFCN_BIN" dns diff does-not-exist.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"does not exist"* ]] || [[ "$output" == *"does-not-exist"* ]]
}

# ---------------------------------------------------------------------------
# ssl diag — mocked Cloudflare API / curl, no real token or network needed
# ---------------------------------------------------------------------------

@test "ssl diag resolves zone, ssl mode, and proxied state through loaded helpers" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"flexible"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=www.example.com"* ]]; then
  printf '{"success":true,"result":[{"type":"A","content":"203.0.113.10","proxied":true}]}\n200'
  exit 0
fi

if [[ "$args" == *"--resolve www.example.com:80:203.0.113.10"* ]]; then
  printf '301'
  exit 0
fi

if [[ "$args" == *"--resolve www.example.com:443:203.0.113.10"* ]]; then
  printf '301'
  exit 0
fi

if [[ "$args" == *"http://www.example.com"* ]]; then
  printf '301'
  exit 0
fi

if [[ "$args" == *"https://www.example.com"* ]]; then
  printf '301'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag www.example.com

  [ "$status" -eq 0 ]
  assert_output_contains "zone:      example.com"
  assert_output_contains "ssl mode:  flexible"
  assert_output_contains "proxied:   true"
}

@test "ssl diag infers origin IP from a single proxied A record and probes direct origin" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"flexible"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=app.example.com"* ]]; then
  printf '{"success":true,"result":[{"type":"A","content":"203.0.113.10","proxied":true}]}\n200'
  exit 0
fi

if [[ "$args" == *"--resolve app.example.com:80:203.0.113.10"* ]]; then
  printf '301'
  exit 0
fi

if [[ "$args" == *"--resolve app.example.com:443:203.0.113.10"* ]]; then
  printf '000'
  exit 0
fi

if [[ "$args" == *"--max-redirs"* && "$args" == *"https://app.example.com/"* ]]; then
  printf '000'
  exit 0
fi

if [[ "$args" == *"http://app.example.com"* ]]; then
  printf '301'
  exit 0
fi

if [[ "$args" == *"https://app.example.com"* ]]; then
  printf '301'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com

  [ "$status" -eq 0 ]
  assert_output_contains "origin IP:          203.0.113.10 (DNS A)"
  assert_output_contains "Origin HTTP/80:     301"
  assert_output_contains "Origin HTTPS/443:   000"
}

@test "ssl diag distinguishes local certificate distrust from unreachable origin HTTPS" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"strict"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=app.example.com"* ]]; then
  printf '{"success":true,"result":[{"type":"A","content":"203.0.113.10","proxied":true}]}\n200'
  exit 0
fi

if [[ "$args" == *"--resolve app.example.com:80:203.0.113.10"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"-k"* && "$args" == *"--resolve app.example.com:443:203.0.113.10"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"--resolve app.example.com:443:203.0.113.10"* ]]; then
  printf 'curl: (60) SSL certificate problem: unable to get local issuer certificate\n' >&2
  exit 60
fi

if [[ "$args" == *"--max-redirs"* && "$args" == *"https://app.example.com/"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"http://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"https://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com

  [ "$status" -eq 0 ]
  assert_output_contains "Origin HTTPS/443 -k: 200  (ignores local certificate trust)"
  assert_output_contains "direct origin HTTPS is reachable, but local curl does not trust the certificate."
  assert_output_contains "Cloudflare Origin CA"
  assert_output_not_contains "direct origin HTTPS failed while SSL mode is 'strict'"
}

@test "ssl diag skips ambiguous multiple proxied A records without --origin-ip" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"full"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=app.example.com"* ]]; then
  printf '{"success":true,"result":[{"type":"A","content":"203.0.113.10","proxied":true},{"type":"A","content":"203.0.113.11","proxied":true}]}\n200'
  exit 0
fi

if [[ "$args" == *"--resolve"* ]]; then
  printf 'unexpected direct origin probe: %s\n' "$args" >&2
  exit 1
fi

if [[ "$args" == *"--max-redirs"* && "$args" == *"https://app.example.com/"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"http://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"https://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com

  [ "$status" -eq 0 ]
  assert_output_contains "origin direct probe skipped (multiple proxied A/AAAA records; use --origin-ip <ip>)"
  assert_output_not_contains "origin IP:"
  assert_output_not_contains "Origin HTTP/80:"
}

@test "ssl diag skips proxied CNAME origin probes without --origin-ip" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"full"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=app.example.com"* ]]; then
  printf '{"success":true,"result":[{"type":"CNAME","content":"origin.example.net","proxied":true}]}\n200'
  exit 0
fi

if [[ "$args" == *"--resolve"* ]]; then
  printf 'unexpected direct origin probe: %s\n' "$args" >&2
  exit 1
fi

if [[ "$args" == *"--max-redirs"* && "$args" == *"https://app.example.com/"* ]]; then
  printf '526'
  exit 0
fi

if [[ "$args" == *"http://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"https://app.example.com"* ]]; then
  printf '526'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com

  [ "$status" -eq 0 ]
  assert_output_contains "origin direct probe skipped (use --origin-ip <ip> for CNAME/multi-origin cases)"
  assert_output_not_contains "origin IP:"
  assert_output_not_contains "Origin HTTP/80:"
}

@test "ssl diag surfaces DNS record lookup failures without disabling edge probes" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"full"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=app.example.com"* ]]; then
  printf '{"success":false,"errors":[{"message":"permission denied"}],"result":null}\n403'
  exit 0
fi

if [[ "$args" == *"--resolve"* ]]; then
  printf 'unexpected direct origin probe: %s\n' "$args" >&2
  exit 1
fi

if [[ "$args" == *"--max-redirs"* && "$args" == *"https://app.example.com/"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"http://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"https://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com

  [ "$status" -eq 0 ]
  assert_output_contains "DNS record lookup failed; origin IP inference disabled."
  assert_output_contains "Edge HTTP/80:       200"
  assert_output_contains "origin direct probe skipped (DNS record lookup failed; use --origin-ip <ip>)"
  assert_output_not_contains "Origin HTTP/80:"
}

@test "ssl diag accepts --origin-ip for proxied CNAME origin probes" {
  cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"

if [[ "$args" == *"api.cloudflare.com/client/v4/zones?name=example.com"* ]]; then
  printf '{"success":true,"result":[{"id":"zone123","name":"example.com"}]}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/settings/ssl"* ]]; then
  printf '{"success":true,"result":{"value":"full"}}\n200'
  exit 0
fi

if [[ "$args" == *"api.cloudflare.com/client/v4/zones/zone123/dns_records?name=app.example.com"* ]]; then
  printf '{"success":true,"result":[{"type":"CNAME","content":"origin.example.net","proxied":true}]}\n200'
  exit 0
fi

if [[ "$args" == *"--resolve app.example.com:80:203.0.113.20"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"--resolve app.example.com:443:203.0.113.20"* ]]; then
  printf '526'
  exit 0
fi

if [[ "$args" == *"--max-redirs"* && "$args" == *"https://app.example.com/"* ]]; then
  printf '526'
  exit 0
fi

if [[ "$args" == *"http://app.example.com"* ]]; then
  printf '200'
  exit 0
fi

if [[ "$args" == *"https://app.example.com"* ]]; then
  printf '526'
  exit 0
fi

printf 'unexpected curl call: %s\n' "$args" >&2
exit 1
EOF
  chmod +x "$TMP/curl"

  PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com --origin-ip 203.0.113.20

  [ "$status" -eq 0 ]
  assert_output_contains "origin IP:          203.0.113.20 (--origin-ip)"
  assert_output_contains "Origin HTTP/80:     200"
  assert_output_contains "Origin HTTPS/443:   526"
}

# ---------------------------------------------------------------------------
# --json flag plumbing — should be accepted even without a token
# ---------------------------------------------------------------------------

@test "--json flag is accepted globally" {
  run "$CFCN_BIN" --json version
  [ "$status" -eq 0 ]
}

@test "--dry-run flag is accepted globally" {
  run "$CFCN_BIN" --dry-run version
  [ "$status" -eq 0 ]
}
