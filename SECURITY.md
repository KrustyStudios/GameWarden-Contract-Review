# Security policy

## Supported versions

Security fixes are made against the current `main` branch. If releases are
published, only the latest release is supported unless a security advisory says
otherwise.

## Report a vulnerability privately

Use GitHub's private vulnerability reporting form:

<https://github.com/KrustyStudios/GameWarden-Contract-Review/security/advisories/new>

Do not open a public issue for a suspected vulnerability. Do not include live
credentials, approval receipts, private contracts, personal paths, or
unredacted run artifacts in a report. If a credential may have been exposed,
revoke or rotate it immediately and then report the incident.

Include the affected commit, the observable impact, minimal reproduction steps,
and sanitized evidence. Fake-provider reproductions are preferred. Maintainers
will coordinate disclosure after the report is understood and a safe response
is available.

## Security-sensitive areas

Reports are especially useful for problems involving:

- approval or authorization bypasses;
- ticket/request influence reaching blind-review prompts;
- provider isolation, authentication, or tool restrictions;
- command construction or process cleanup;
- path traversal, symlink, or repository-boundary escapes;
- secret, private-file, or runtime-artifact disclosure;
- fail-open behavior after interrupted or invalid reviews.
