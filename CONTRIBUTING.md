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

### Newsletter visual QA

Generate retained, synthetic integration fixtures (never use private output):

```powershell
pwsh ./scripts/test-newsletter-integration.ps1 -EngineFilter windows -ScenarioFilter active,quiet -KeepArtifacts
```

Use each reported fixture's `app` directory (`data` for container renderers)
with an installed Playwright module and an isolated Chromium executable:

```text
node scripts/test-recipient-watched-visuals.mjs "<fixture>/app" "<fixture>/visual-qa" "<playwright>/index.mjs" "<chromium-executable>"
```

The check uses a temporary browser profile, blocks non-local requests, validates
all six lifecycle previews plus Index at 1280px, 390px, and 320px, and saves
synthetic screenshots and geometry outside the repository. Signature-only JPEG
test probes are displayed as code-native poster surrogates; missing files still
fail. It checks native icon sizes, the 6px gap, text centering within one pixel,
orphan-free wrapping, desktop overlay geometry, and broken image references.
Classic Outlook VML is checked structurally by the focused renderer tests;
browser results are not a native Outlook-client certification.

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
