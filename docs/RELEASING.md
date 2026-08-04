# Release process

Releases are created by the tagged-release workflow and must originate from a
reviewed commit on `main`.

1. Confirm CI, Pages, and Container workflows are green on `main`.
2. Update `CHANGELOG.md` and move the intended entries from `Unreleased` into a
   semantic version heading.
3. Run local validation and packaging:

   ```powershell
   pwsh ./scripts/validate-repository.ps1
   pwsh ./scripts/validate-unraid-template.ps1
   pwsh ./scripts/check-links.ps1
   pwsh ./scripts/build-releases.ps1 -Version 1.2.3
   ```

4. Inspect `dist/SHA256SUMS.txt` and list every archive to confirm that no live
   configuration, state, logs, or generated output is present.
5. Create and push an annotated tag from `main`:

   ```bash
   git tag -a v1.2.3 -m "TautWeekly for Plex v1.2.3"
   git push origin v1.2.3
   ```

6. The release workflow rebuilds the archives, generates SHA-256 checksums, and
   creates the GitHub release. The Container workflow publishes matching
   `linux/amd64` and `linux/arm64` tags to
   `ghcr.io/sparkmoxie/tautweekly`. Download the published artifacts, inspect
   the multi-platform image manifest, and verify both independently.

7. Keep the container package public so Unraid Community Apps can pull it
   anonymously. Validate `ca_profile.xml` and `templates/tautweekly.xml` before
   submitting the repository through the Unraid Community Applications portal.

Do not create a release from an unreviewed feature branch, and never add a live
configuration to a release for testing.
