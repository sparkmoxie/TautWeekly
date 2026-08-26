# Release process

Releases are created by the tagged-release workflow and must originate from a
reviewed commit on main.

1. Confirm CI, Pages, and Container workflows are green on main.
2. Optimize every new or changed bundled local asset losslessly before
   deployment, verify decoded equivalence and byte counts, and keep the original
   when a verified candidate is not smaller. Update CHANGELOG.md, move intended
   entries out of Unreleased, and synchronize the public Manager preview with
   `node scripts/sync-gui-preview.mjs` after frontend/version changes.
3. Run checks proportionate to the change. A container-platform release normally
   includes:

   ~~~powershell
   pwsh ./scripts/validate-repository.ps1
   pwsh ./scripts/validate-unraid-template.ps1
   pwsh ./scripts/validate-platforms.ps1
   pwsh ./scripts/validate-docs.ps1
   pwsh ./scripts/check-links.ps1
   pwsh ./scripts/build-releases.ps1 -Version 1.2.3
   pwsh ./scripts/test-release-artifacts.ps1 -Version 1.2.3
   ~~~

   Reuse passing CI evidence for the exact commit or identical tree rather than
   duplicating comprehensive work locally. Do not claim physical Intel Mac,
   Apple-silicon Mac, NAS appliance, QNAP, Unraid, or FreeBSD validation when
   only Buildx/QEMU or ordinary Linux runners were available.
4. Inspect dist/SHA256SUMS.txt, all nine archives, TautWeekly-Setup.exe,
   TautWeekly-compose.yaml, and TautWeekly-mac-compose.yaml. The checksum file
   must cover exactly those twelve artifacts. Confirm no live configuration,
   state, credentials, logs, histories, output, or private infrastructure
   material is present. Confirm each archive contains RELEASE-FILES.txt and
   that Mac fallback app entries match the canonical container payload.
5. Create and push an annotated tag from the reviewed main commit:

   ~~~bash
   git tag -a v1.2.3 -m "TautWeekly for Plex v1.2.3"
   git push origin v1.2.3
   ~~~

6. The release workflow rebuilds and validates all artifacts, then invokes the
   reusable Container workflow. That workflow runs the fail-closed profile
   selector suite, boots server, desktop, and unraid on linux/amd64, boots
   server on linux/arm64 through QEMU, and publishes one manifest:

       ghcr.io/sparkmoxie/tautweekly

   The manifest must contain linux/amd64 and linux/arm64 and include provenance
   and SBOM attestations. The GitHub release job depends on the artifact,
   Windows-installer, and unified-image jobs, so it cannot publish release notes
   after a failed image publication.

   Image publication necessarily precedes the final GitHub release API call.
   Those systems are not transactional: if the final call fails, the semver
   image can temporarily exist without the GitHub release. Diagnose and rerun
   the failed release job for the same tag and commit; never move the tag or
   publish different content under that semver.

7. Stable tags publish full semver, the mutable major/minor tag, and mutable
   latest. A relevant main push publishes edge. Full semver is the readable
   supported default; the release manifest digest is the immutable automation
   reference. Never recommend minor, latest, or edge for unattended CI/CD
   promotion. Unraid may retain latest only because its host-owned Apps
   lifecycle presents digest changes for administrator review.
8. Download the public release assets anonymously and verify SHA256SUMS.txt.
   Exercise an anonymous pull or registry-manifest request for the full-semver
   image, verify its platforms, digest, labels, and attestations, and confirm
   every shipped Compose file resolves to that release semver. Validate
   ca_profile.xml and templates/tautweekly.xml before any Unraid Community
   Applications submission.
9. Exercise package-owned update, rollback, busy-operation refusal, health,
   version, and persistence paths. Confirm desktop loopback and
   host.docker.internal guidance; server/Unraid trusted-LAN guidance; named and
   bind-mounted /data; PUID/PGID/UMASK; Manager pairing/privacy; schedule and
   history persistence; graceful stop; interrupted pull/recreate recovery; and
   old-image rollback. Windows keeps its verified native updater; Linux keeps
   its systemd package; FreeBSD keeps its Podman beta adapter.

The old ghcr.io/sparkmoxie/tautweekly-mac:0.22.0 manifest remains a rollback
source and receives no new release tags. TautWeekly-mac-compose.yaml is a
transitional desktop-profile asset through v0.24.x and may be removed no
earlier than v0.25.0 with release-note notice. It points to the unified image
and does not represent a second published payload.

Do not create a release from an unreviewed feature branch, retag different
content, disable required gates, or add live configuration to a release test.
