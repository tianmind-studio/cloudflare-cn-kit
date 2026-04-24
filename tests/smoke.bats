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
