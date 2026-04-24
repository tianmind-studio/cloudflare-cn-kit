# Changelog

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
