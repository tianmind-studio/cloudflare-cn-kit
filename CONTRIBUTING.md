# Contributing to cloudflare-cn-kit

## What this project is (and isn't)

`cfcn` is a small, opinionated CLI for the specific operations CN/HK
operators actually do against Cloudflare. It is **not** a full wrapper around
the Cloudflare API — `flarectl` already exists and does that.

Before proposing a new feature, ask: "does this improve a workflow that
someone running multiple zones from China/HK actually repeats?" If yes,
open an issue. If no, it's probably not a fit.

## Bug reports

Include:

1. `cfcn version` + `bash --version`.
2. Redacted but full output of the failing command with your token having
   the right scopes.
3. Output of `cfcn doctor`.

## Adding a new subcommand

Match the existing shape. Each new subcommand lives in `lib/<area>.sh`
exposing a `cfcn_<area>()` dispatcher:

```bash
cfcn_<area>() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    foo) ... ;;
    bar) ... ;;
    help|"") cat <<'EOF' ... EOF ;;
    *) cfcn_err "unknown $area subcommand: $sub"; return 2 ;;
  esac
}
```

Every write operation must:

- Honor `--dry-run` (wrap external calls accordingly).
- Use `cfcn_api` rather than raw curl (centralized error handling).
- Emit `--json` raw mode when `$CFCN_JSON == 1`.

## The `ssl diag` bar

The single most valuable command in this repo is `cfcn ssl diag`. If you
propose a new diagnostic pattern, include:

1. The exact symptom a user would observe (HTTP status, browser error, etc.).
2. The root cause in one sentence.
3. The fix, with at least two options when possible.

The diagnostic output should tell the operator **both what is wrong and what
to do next** — not just "Flexible SSL is on".

## Testing

- `shellcheck -x -e SC1091 -e SC2155 bin/cfcn lib/*.sh`
- `./bin/cfcn --help`
- `./bin/cfcn doctor` (needs a valid token)
- Manual: spin up a throwaway zone, set Flexible + force HTTPS on origin,
  run `cfcn ssl diag` to confirm it catches the loop.

## Commit messages

Conventional commits as elsewhere: `feat(ssl): ...`, `fix(dns): ...`.

## License

MIT for submissions, same as the project.
