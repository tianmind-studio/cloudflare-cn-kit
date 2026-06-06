# M3 Origin-aware SSL Diagnostics Implementation Plan

> **Status:** Implemented for the v0.1.3 milestone; kept as a reviewable engineering plan for future contributors.

**Goal:** Make `cfcn ssl diag` distinguish Cloudflare edge behavior from direct-origin behavior so operators can tell whether HTTPS breakage is caused by Cloudflare mode, origin redirects, origin TLS/certs, HSTS, or CN network path issues.

**Architecture:** Keep the CLI dependency-free Bash. Extend `ssl diag` only; do not add automatic write/fix commands. Reuse Cloudflare DNS record data to infer an origin IP for proxied A/AAAA records, allow `--origin-ip <ip>` override for CNAME/multi-origin cases, and print edge vs origin probe results separately.

**Tech Stack:** Bash, curl, jq, awk, Bats, ShellCheck.

---

### Task 1: Add failing offline tests for origin-aware diag

**Objective:** Lock down the user-facing behavior before implementation.

**Files:**
- Modify: `tests/smoke.bats`

**Step 1: Add mocked curl test for inferred A-record origin**

Append a Bats test that mocks Cloudflare API and curl probes. The DNS record response should include:

```json
{"success":true,"result":[{"type":"A","content":"203.0.113.10","proxied":true}]}
```

Expected assertions:

```bash
[[ "$output" == *"origin IP: 203.0.113.10"* ]]
[[ "$output" == *"Origin HTTP/80:"* ]]
[[ "$output" == *"Origin HTTPS/443:"* ]]
```

**Step 2: Add mocked curl test for `--origin-ip` override**

The DNS record response can be a proxied CNAME. Invoke:

```bash
PATH="$TMP:$PATH" CFCN_TOKEN="***" run "$CFCN_BIN" ssl diag app.example.com --origin-ip 203.0.113.20
```

Expected assertions:

```bash
[[ "$output" == *"origin IP: 203.0.113.20"* ]]
[[ "$output" == *"Origin HTTP/80:"* ]]
```

**Step 3: Verify RED**

Run:

```bash
bats tests/smoke.bats
```

Expected: FAIL because current `ssl diag` has no origin probe output or `--origin-ip` parsing.

---

### Task 2: Implement origin IP inference and override parsing

**Objective:** Let `ssl diag` decide whether a direct-origin probe is possible.

**Files:**
- Modify: `lib/ssl.sh`
- Modify: `bin/cfcn` only for help text if needed

**Implementation shape:**

Inside `cfcn_ssl()` for `diag`, parse optional flags after domain:

```bash
local domain="${1:?usage: ssl diag <domain> [--origin-ip <ip>]}"
shift || true
local origin_ip=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin-ip) origin_ip="${2:?usage: ssl diag <domain> --origin-ip <ip>}"; shift 2 ;;
    *) cfcn_err "unknown ssl diag option: $1"; return 2 ;;
  esac
done
_cfcn_ssl_diag "$domain" "$origin_ip"
```

In `_cfcn_ssl_diag(domain, origin_ip_override)`, after DNS lookup fetch the first matching DNS record once:

```bash
local dns_type="" dns_content=""
# result fields: type, content, proxied
```

If no override and the DNS record type is `A` or `AAAA`, set `origin_ip` to record content. If type is CNAME or missing, keep empty and print a hint to retry with `--origin-ip`.

**Step 3: Verify GREEN part 1**

Run the targeted Bats tests. Expected: still fail until probes are added, but no syntax errors.

---

### Task 3: Add direct-origin probes and output

**Objective:** Print edge and direct-origin results separately without changing write behavior.

**Files:**
- Modify: `lib/ssl.sh`

**Implementation shape:**

Keep the existing edge probes. Rename output labels to make semantics explicit:

```text
Edge HTTP/80:       <code>
Edge HTTPS/443:     <code>
Edge HTTPS with -L: <code> (up to 10 redirects)
```

If `origin_ip` is available, run direct-origin probes:

```bash
curl ... --resolve "$domain:80:$origin_ip" "http://$domain"
curl ... --resolve "$domain:443:$origin_ip" "https://$domain"
```

Print:

```text
origin IP:          <ip>
Origin HTTP/80:     <code>
Origin HTTPS/443:   <code>
```

If no origin IP is available, print a non-fatal hint:

```text
origin direct probe skipped (use --origin-ip <ip> for CNAME/multi-origin cases)
```

**Step 3: Verify GREEN**

Run:

```bash
bats tests/smoke.bats
bash -n bin/cfcn lib/*.sh
```

Expected: all tests pass, syntax clean.

---

### Task 4: Refine diagnosis messages using origin data

**Objective:** Avoid overclaiming; use origin probes to make advice more precise.

**Files:**
- Modify: `lib/ssl.sh`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Optional: `docs/flexible-ssl-loop.md`, `docs/index.html`

**Behavior:**
- Flexible + proxied remains a high-risk warning.
- If origin HTTP is a redirect and origin HTTPS fails/errors, add a stronger warning: origin redirect/TLS setup likely causes the Flexible loop.
- If Full/Strict and origin HTTPS fails/errors, recommend installing/renewing origin cert or Cloudflare Origin CA.
- If origin direct probe is unreachable, label it as a probe limitation when origin firewall only allows Cloudflare IPs.

**Docs:**
- Update README killer-feature sample to show Edge vs Origin labels.
- Add `--origin-ip` to command reference/help if implemented.
- Add `[0.1.3]` changelog section describing origin-aware diagnostics.

---

### Task 5: Final verification and PR prep

**Objective:** Make M3 safe to review and merge.

**Commands:**

```bash
git diff --check
PATH="$HOME/Library/Python/3.9/bin:$PATH" shellcheck -x -e SC1091 -e SC2155 bin/cfcn lib/*.sh install.sh
bash -n install.sh && bash -n bin/cfcn && for f in lib/*.sh; do bash -n "$f"; done
bats tests/smoke.bats
```

**Acceptance criteria:**
- Existing `ssl diag` mocked test still passes.
- New origin-aware tests pass without real Cloudflare credentials or network.
- No token value is printed.
- `ssl diag` remains read-only.
- Output clearly distinguishes Edge vs Origin.
- Users with proxied CNAME/multiple origins get a clear `--origin-ip` path instead of misleading diagnosis.
