## Summary

<!-- One or two sentences. What changes, why. -->

## Changes

<!-- Bulleted list. -->

## Test plan

- [ ] `shellcheck -x -e SC1091 bin/cfcn lib/*.sh install.sh` passes
- [ ] `bats tests/` passes
- [ ] `./bin/cfcn --help`, `./bin/cfcn version`, and `./bin/cfcn doctor` still work
- [ ] If DNS/SSL logic changed: token-free smoke tests or mocked tests cover the changed path
- [ ] If a new command/flag was added: a smoke test covers it in `tests/smoke.bats`

## Scope

<!-- Tick one. Tools that creep outside scope get rejected — see CONTRIBUTING.md. -->

- [ ] Bug fix (no new feature)
- [ ] New feature that fits the "good fit" list
- [ ] Docs / CI only
- [ ] Breaking change (describe migration below)
