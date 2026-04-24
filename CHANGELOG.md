# Changelog

## Unreleased

### Added
- `cfcn dns diff <yaml>` — preview what `dns bulk <yaml>` would change,
  without writing anything. Prints a four-way color-coded diff:
  `+` create, `~` update (with before → after), `=` unchanged, `.`
  unmanaged (live-only records that `dns bulk` won't touch). Completes
  the GitOps triangle: `dns export` → edit → `dns diff` → `dns bulk`.
- `cfcn ssl diag` now reports the observed HSTS header and adds three
  new diagnostic patterns:
  - **HSTS preload trap** — warns any time the response header contains
    `preload`. Once submitted to browser preload lists, removal takes
    months of uncontrollable browser update cycles; most operators enable
    `preload` without realizing this.
  - **HSTS max-age=0** — flags an effectively-disabled HSTS that's almost
    always a config typo.
  - **CF 525/526** — distinct message when Cloudflare itself signals a
    broken TLS handshake with origin (525) or invalid origin cert (526).
    The existing Flexible-SSL pattern covered the "loop" failure mode;
    these cover the "Full (strict) but cert broke" failure mode.
- CN-ISP RST pattern is now refined: the previous version flagged any
  `HTTPS 000` on a proxied zone. It now parses the curl error text and
  distinguishes "connection reset" (the real CN-RST signature, now with
  a specific mitigation path), "timed out" (propagation), and TLS
  handshake failure (rare, but distinct).

## [0.1.1] — minor feature release

### Added
- `cfcn dns export <zone> [--out <file>]` — dump a zone's DNS records to
  YAML in the same schema `cfcn dns bulk` consumes. Round-trips cleanly
  for A records; AAAA/CNAME/MX/TXT/SRV/NS/CAA are preserved as YAML
  comments (so you don't silently lose them during migration).
- Typical uses: pre-migration snapshot before moving zones; GitOps review
  of what's currently in Cloudflare; diffing two zones.
- `install.sh` — user-scope installer matching `site-bootstrap` pattern.

## [0.1.0] — initial public release

### Added
- `cfcn zone list | show | ssl | purge` — zone-level ops.
- `cfcn dns list | add | del | bulk | wildcard` — DNS ops, zone auto-inferred from FQDN.
- `cfcn ssl diag <domain>` — the **Flexible-SSL redirect loop diagnostic**, a
  CN-region-specific production-killer that Cloudflare's own dashboard won't
  surface. Walks your zone settings + DNS proxied state + live probes and
  matches against known failure patterns.
- `cfcn ssl mode | hsts` — TLS settings in one place.
- `cfcn cn ping | trace` — points at `itdog.cn`, `ping.chinaz.com`, and
  `ipip.net` as the practical CN observation-point tools.
- `cfcn doctor` — verify token scopes before doing anything destructive.
- `--dry-run` everywhere; `--json` for scripting.
- `docs/flexible-ssl-loop.md` — long-form explanation of the bug the diag
  catches, with two concrete fix paths.

### Design notes
- Scoped API tokens only (`Zone:Zone:Read`, `Zone:DNS:Edit`). No global key.
- Zero dependencies beyond `curl` + `jq` + `awk`.
- Token can be provided via `CFCN_TOKEN` or `CF_API_TOKEN` (site-bootstrap compatible).
