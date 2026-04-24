# Security policy

## Reporting a vulnerability

If you believe you've found a security-relevant bug in cloudflare-cn-kit,
please do **not** open a public issue. Instead, email:

**wx@tianmind.com**

with "cfcn security:" in the subject. Include:

- A description of the issue.
- The command affected.
- The impact — especially credential leakage or unintended zone mutation.

You should get a reply within 3 business days.

## What is in scope

- Token exposure: any path where the CFCN_TOKEN or CF_API_TOKEN could end
  up in shell history, process listings visible to other users, or a log
  file.
- Unintended zone mutation: any case where a command that looks read-only
  writes something, or a `--dry-run` path actually mutates state.
- Hostile Cloudflare API response triggering RCE in cfcn's parse path.

## What is not in scope

- Operator shares a globally-scoped token with cfcn (we explicitly warn
  against this; use `Zone:Zone:Read + Zone:DNS:Edit`).
- Cloudflare API rate-limiting / temporary account lockouts caused by
  running `dns bulk` against a huge zone too fast.

## Disclosure

Coordinated. Reporters who ask will be credited in the release notes.
