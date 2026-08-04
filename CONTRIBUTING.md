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
pwsh ./scripts/check-links.ps1
pwsh ./scripts/build-releases.ps1 -Version dev
```

On a Unix-like host, also run:

```bash
find platforms scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck $(find platforms scripts -type f -name '*.sh')
docker compose -f platforms/nas-docker/compose.yaml config --quiet
docker compose -f platforms/mac-docker/compose.yaml config --quiet
```

PowerShell changes must parse under the runtime declared by their platform:
Windows PowerShell 5.1 for Windows and PowerShell 7.2 or newer for Docker.

## Pull requests

Explain what changed, why it is safe, which platforms are affected, and which
checks were run. Include sanitized screenshots for documentation or rendering
changes. Small, reviewable pull requests are preferred.

By contributing, you agree that your original contribution is licensed under
the repository's MIT license. Do not submit assets or code that you do not have
permission to redistribute.
