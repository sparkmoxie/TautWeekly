# Contributing to TautWeekly for Plex

Thanks for helping make TautWeekly for Plex safer and easier to operate.

## Before opening a change

1. Search existing issues and pull requests.
2. Keep platform-specific behavior intact unless the change explicitly updates
   the support matrix.
3. Use only sanitized example values. Never commit live configuration, state,
   logs, generated output, API keys, tokens, SMTP credentials, email addresses,
   server names, private addresses, or machine-specific paths.
4. Preserve the preview-before-send and explicit confirmation safeguards.

## Development workflow

Create a focused branch and use conventional commit messages such as
`fix(windows): handle missing schedule state` or
`docs(nas): clarify compose networking`.

Run the repository checks before opening a pull request:

```powershell
pwsh ./scripts/validate-repository.ps1
pwsh ./scripts/validate-platforms.ps1
pwsh ./scripts/check-links.ps1
pwsh ./scripts/build-releases.ps1 -Version dev
```

On a Unix-like host, also run:

```bash
./scripts/validate-shell.sh
docker compose -f platforms/nas-docker/compose.yaml config --quiet
docker compose -f platforms/mac-docker/compose.yaml config --quiet
```

PowerShell changes must parse under the runtime declared by their platform:
Windows PowerShell 5.1 for Windows and PowerShell 7.2 or newer for Docker and
native Linux. FreeBSD uses the maintained Linux OCI runtime; its host wrappers
must remain POSIX sh and rc.d compatible.

## Pull requests

Explain what changed, why it is safe, which platforms are affected, and which
checks were run. Include sanitized screenshots for documentation or rendering
changes. Small, reviewable pull requests are preferred.

## Contributor attribution

After a community contribution ships, update the [contributors ledger](CONTRIBUTORS.md)
using the existing evidence hierarchy:

- `🐛 bug` credits the human reporter when their report leads to an implemented
  correction.
- `💡 enhancement` credits the human proposer when their feature request is
  implemented.
- Link the public issue, merged pull request, and first release containing the
  change so the attribution can be independently verified.

Use public GitHub handles only. Do not credit duplicates that produced no
distinct correction, invalid or unshipped reports, maintainer housekeeping, or
the implementer in place of the original reporter or proposer. Attribution is
not commit co-authorship; use `Co-authored-by` only for actual commit authors.

By contributing, you agree that your original contribution is licensed under
the repository's MIT license. Do not submit assets or code that you do not have
permission to redistribute.
