# Release process

Releases are created by the tagged-release workflow and must originate from a
reviewed commit on `main`.

1. Confirm CI, Pages, and Container workflows are green on `main`.
2. Optimize new/changed bundled local assets losslessly before deployment,
   verify equivalence, and record measured sizes (see `AGENTS.md`). Resizing
   requires explicit authorization. Verify GIF mirrors with
   `python3 -B scripts/optimize-email-gifs.py --check`.
   Update `CHANGELOG.md` and move the intended entries from `Unreleased` into a
   semantic version heading. Synchronize the public Manager preview with
   `node scripts/sync-gui-preview.mjs` after frontend/version changes;
   documentation validation checks the generated copy and release label.
3. Choose local checks proportionate to the patch (see AGENTS.md). Reuse passing
   CI evidence for the exact commit or identical tree instead of duplicating
   comprehensive suites locally. The relevant commands include:

   ```powershell
   pwsh ./scripts/validate-repository.ps1
   pwsh ./scripts/validate-unraid-template.ps1
   pwsh ./scripts/validate-platforms.ps1
   pwsh ./scripts/check-links.ps1
   pwsh ./scripts/build-releases.ps1 -Version 1.2.3
   ```

4. Inspect `dist/SHA256SUMS.txt`, all nine archives, and
   `TautWeekly-mac-compose.yaml` to confirm that no
   live configuration, state, logs, or generated output is present. Confirm the
   Linux archive contains the canonical application payload and systemd unit;
   confirm the FreeBSD archive contains the same payload, Dockerfile, and rc.d
   integration. Confirm every archive also contains `RELEASE-FILES.txt`, whose
   per-file hashes define release ownership without claiming private runtime
   paths. The Windows updater depends on that manifest for verified replacement
   and deprecated-file cleanup.
5. Create and push an annotated tag from `main`:

   ```bash
   git tag -a v1.2.3 -m "TautWeekly for Plex v1.2.3"
   git push origin v1.2.3
   ```

6. The release workflow rebuilds the archives and standalone Mac Compose asset,
   generates SHA-256 checksums, and invokes the reusable Container workflow.
   That workflow publishes matching `linux/amd64` and `linux/arm64` manifests to
   `ghcr.io/sparkmoxie/tautweekly` for NAS/FreeBSD and
   `ghcr.io/sparkmoxie/tautweekly-mac` for macOS Docker Desktop. The GitHub
   release job depends on both image jobs plus archive and Windows-installer
   validation; it cannot publish a release that advertises a missing image.

   Image publication necessarily precedes the final GitHub release API call. If
   that last call fails, the semver image can temporarily exist without a
   GitHub release; diagnose and rerun the release job rather than retagging a
   different commit. This is the documented non-transactional boundary.
   Download the published artifacts, inspect both multi-platform manifests and
   attestations, and verify them independently.

   Stable tags publish the full semantic version, the major/minor tag, and
   `latest` to each manifest. A relevant push to `main` publishes only `edge`.
   Recommend full semver or the release manifest digest—not mutable `latest`,
   minor, or `edge`—for CI/CD. Confirm no packaged Compose file, Unraid template,
   environment example, or update guide defaults to `edge`. Exercise each packaged `check-update`/apply path against
   the release candidate, including busy-operation refusal, health/version
   verification, and rollback where the platform owns updates. On Windows,
   exercise checksum refusal, the shared operation lock, private-file
   preservation, Task Scheduler restoration, and automatic folder rollback.

7. Keep both container packages public so Unraid Community Apps and standalone
   Mac Docker Desktop installs can pull anonymously. Validate `ca_profile.xml`
   and `templates/tautweekly.xml` before submitting the repository through the
   Unraid Community Applications portal.

Do not create a release from an unreviewed feature branch, and never add a live
configuration to a release for testing.
