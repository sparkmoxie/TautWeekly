# Release process

Releases are created by the tagged-release workflow and must originate from a
reviewed commit on `main`.

1. Confirm CI, Pages, and Container workflows are green on `main`.
2. Update `CHANGELOG.md` and move the intended entries from `Unreleased` into a
   semantic version heading.
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

4. Inspect `dist/SHA256SUMS.txt` and list all nine archives to confirm that no
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

6. The release workflow rebuilds the archives, generates SHA-256 checksums, and
   creates the GitHub release. The Container workflow publishes matching
   `linux/amd64` and `linux/arm64` tags to
   `ghcr.io/sparkmoxie/tautweekly`. That image is consumed by NAS and FreeBSD
   Podman installations. Download the published artifacts, inspect the
   multi-platform image manifest, and verify both independently.

   Stable tags publish the full semantic version, the major/minor tag, and
   `latest` to one manifest. A push to `main` publishes only `edge`. Confirm no
   packaged Compose file, Unraid template, environment example, or update guide
   defaults to `edge`. Exercise each packaged `check-update`/apply path against
   the release candidate, including busy-operation refusal, health/version
   verification, and rollback where the platform owns updates. On Windows,
   exercise checksum refusal, the shared operation lock, private-file
   preservation, Task Scheduler restoration, and automatic folder rollback.

7. Keep the container package public so Unraid Community Apps can pull it
   anonymously. Validate `ca_profile.xml` and `templates/tautweekly.xml` before
   submitting the repository through the Unraid Community Applications portal.

Do not create a release from an unreviewed feature branch, and never add a live
configuration to a release for testing.
