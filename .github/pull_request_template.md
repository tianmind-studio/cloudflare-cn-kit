## Summary

<!-- One or two sentences. What changes, why. -->

## Changes

<!-- Bulleted list. -->

## Test plan

- [ ] `shellcheck -x -e SC1091 bin/site-bootstrap lib/*.sh install.sh` passes
- [ ] `bats tests/` passes
- [ ] `./bin/site-bootstrap --help` and `doctor` still work
- [ ] If deploy logic changed: `--dry-run deploy` against a minimal `site.yaml` prints the expected steps
- [ ] If a new command/flag was added: a smoke test covers it in `tests/smoke.bats`

## Scope

<!-- Tick one. Tools that creep outside scope get rejected — see CONTRIBUTING.md. -->

- [ ] Bug fix (no new feature)
- [ ] New feature that fits the "good fit" list
- [ ] Docs / CI only
- [ ] Breaking change (describe migration below)
