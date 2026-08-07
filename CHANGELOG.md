# Changelog

All notable public changes to TautWeekly for Plex will be documented here. The project
uses [Semantic Versioning](https://semver.org/) for GitHub releases and follows
the structure of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Added explicit stable-release checks for Windows, macOS, and native Linux,
  plus stage-only image checks for NAS/QNAP and FreeBSD.
- Added regression contracts for stable-channel defaults, check/apply
  separation, operation-lock refusal, health/version verification, and
  automatic container-image rollback.

### Changed

- Defined one package-by-package update policy across the README, Markdown
  guides, and rendered Quickstarts. Stable releases remain the default,
  unattended application is opt-in, and `edge` is documented as unreleased
  `main` rather than an update channel.
- Made NAS/QNAP Compose and FreeBSD updates preserve state, reject concurrent
  TautWeekly operations, verify the replacement container, and restore the
  prior image automatically after a failed health check.

### Fixed

- Corrected macOS `update`: it now builds the verified release package present
  on disk, records that repository version in the image, verifies health and
  version, and rolls back on failure instead of only refreshing the base image.
- Removed FreeBSD's ineffective Podman registry auto-update label; Podman auto
  update requires a systemd-managed container, while this package uses rc.d.

## [0.5.4] - 2026-08-07

### Added

- Added global movie/TV library discovery and selection to every primary setup
  flow, using stable Tautulli section IDs and preserving legacy all-library
  behavior for configurations without an explicit selection.
- Added standalone list and management commands for Windows, NAS/Unraid,
  macOS, native Linux, and FreeBSD, including configuration backup and stale-ID
  verification.
- Added deterministic virtual Tautulli/Plex integration scenarios for active
  and quiet release weeks, cross-platform command-routing tests, packaged
  runtime contract checks, and checksum verification for every distribution.

### Changed

- Consolidated the separate Docker Compose quick-start page into the canonical
  NAS / Docker guide. Compose, QNAP Container Station, Unraid Apps, and Docker
  Desktop are now presented as deployment paths for one package; the retired
  `quickstart.html` URL redirects to the consolidated guide.
- Routed top-level Unraid references through the consolidated NAS Quickstart or
  Markdown documentation; the detailed NAS guides retain the published
  Community Apps installation destination in context, including the platform
  comparison shortcut.
- Separated interactive Quickstarts from source-oriented documentation and
  standardized the platform labels across the README, Pages hub, rendered HTML,
  and standalone installation guides.
- Query each selected Tautulli section independently for history and
  recently-added media, then fail closed on mismatched rows before calculating
  releases, quiet mode, Trending, hero content, Binge Champion, and personal
  statistics. Busy private libraries can no longer crowd selected releases out
  of paged API results.
- Allow the FreeBSD Podman binary path to be set with
  `TAUTWEEKLY_PODMAN_BIN`, while retaining `/usr/local/bin/podman` as the
  package default.

### Fixed

- Clarified that `./tautweekly.sh` is a host-side Docker Compose wrapper, not a
  command inside the Unraid Apps container, and replaced container-generated
  follow-up guidance with commands that exist in the Unraid Console.
- Made every non-Windows scheduler resolve and convert UTC through the configured
  IANA `TZ` explicitly instead of trusting process-local `Get-Date`; invalid
  zones now fail closed instead of silently scheduling in UTC. Schedule status
  now distinguishes the control process from the active scheduler heartbeat,
  including the resolved zone, local time, and UTC offset.
- Replaced the legacy SMTP send path with an explicit STARTTLS and
  `AUTH LOGIN`/`AUTH PLAIN` transport that requires authentication success
  before `MAIL FROM`, including compatibility with Proton SMTP submission.
- Corrected Unraid Console examples to pass the required numeric `USER_ID`,
  clarified that `ListUsers` is display-only across every launcher and guide,
  and documented that `verify` checks SMTP reachability rather than login or
  sender authorization.
- Corrected the selected-library row predicate on all renderers. PowerShell
  previously accepted an unsupported parameter without binding the row,
  causing every history and release item to be rejected whenever an explicit
  library scope was enabled.

## [0.5.3] - 2026-08-05

### Fixed

- Replaced Docker health's scheduler-progress dependency with a five-second
  service-supervisor heartbeat, preventing long scheduled deliveries from
  making a working container appear unhealthy.
- Made missing decorative preview artwork a repair warning rather than a
  liveness failure, while retaining hard failures for an unavailable preview
  listener and a missing, unreadable, or stale supervisor heartbeat.
- Added actionable health-probe errors and an eight-scenario functional suite
  covering failure isolation and automatic recovery.

## [0.5.2] - 2026-08-05

### Fixed

- Replaced exclusion setup's per-user `get_user` requests with a two-call merge
  of Tautulli's `get_user_names` and `get_users` rosters. Stable IDs from the
  name roster remain selectable when detailed rows are unavailable.
- Added a bulk-roster fallback for newsletter user resolution when a Tautulli
  installation rejects an otherwise valid single-user lookup.

## [0.5.1] - 2026-08-05

### Added

- Added a standalone, responsive eight-state newsletter showcase with real
  public Plex Discover posters and title art, dated Rotten Tomatoes movie and
  IMDb episode score examples, production-formatted TV episode rows, dense
  movie/TV releases, both anonymous Binge Champion treatments, onboarding and
  warmup variants, and the production quiet-week latest-release fallback.

### Fixed

- Treat Tautulli episode `rating_image` and `rating` fields as optional when
  building personal statistics, preventing `preview-all` from failing under
  strict PowerShell property handling when either field is omitted.
- Added a permanent first-run page to the container preview endpoint, verified
  its listener before starting the scheduler, and made an unexpected preview
  or scheduler process exit fail the container visibly.
- Corrected NAS documentation that pointed to a nonexistent `preview-all/`
  subdirectory; the generated index is `/preview-all-00-INDEX.html`.

### Changed

- Docker and Unraid startup logs now identify the exact persistent
  `/data/config.json` path and provide the appropriate Compose or Console setup
  command. Documentation and Community Apps metadata now distinguish the
  read-only preview viewer from an administration Web UI.

## [0.5.0] - 2026-08-04

### Added

- Added a standalone native Linux distribution with PowerShell 7.2+, a
  hardened systemd service, protected `/var/lib/tautweekly` storage, safe
  in-place upgrades, and matching administrative commands.
- Added a FreeBSD 15.1+ amd64 beta distribution using FreeBSD Podman Linux
  containers, rc.d lifecycle integration, protected `/var/db/tautweekly`
  storage, image pinning, updates, and private backups.
- Added rich searchable Linux and FreeBSD Pages walkthroughs, standalone
  Markdown install guides, platform troubleshooting, security boundaries, and
  support-matrix entries.
- Added Linux and FreeBSD ZIP/TAR.GZ release artifacts, checksum coverage,
  launcher-permission checks, and platform-contract validation.

### Changed

- Made container runtime wrappers honor configurable application and data roots
  so the canonical renderer can be packaged for native Linux without source
  drift.

## [0.4.0] - 2026-08-04

### Added

- Added interactive Tautulli user exclusion selection to every platform's
  primary setup and a standalone exclusion manager for later recipient-policy
  updates.
- Added Windows and Docker launch commands, selection behavior tests, and
  matching Markdown and rendered walkthrough guidance.

### Changed

- Setup replacement now carries forward existing `ExcludedUserIds` and
  `ExcludedEmails`; a temporary Tautulli lookup failure no longer silently
  clears established exclusions.
- Binge Champion now ranks qualifying users by total watch time, with total
  plays as the exact-time tie-breaker.
- Binge Champion output now shares only anonymous movie-play, TV-play, and
  watch-time totals. Friendly names, user identifiers, and titles are hidden;
  only the winner receives the gold **YOU WON** treatment.

## [0.3.0] - 2026-08-04

### Added

- Added an official Unraid Community Applications v2 Docker template and root
  `ca_profile.xml` with safe appdata, port, identity, and timezone defaults.
- Added automated amd64/arm64 container publishing to
  `ghcr.io/sparkmoxie/tautweekly` with OCI source metadata, SBOM, provenance,
  version tags, and a stable `latest` tag.
- Added a pull-based QNAP Container Station Compose application while keeping
  the source Dockerfile and local-build workflow maintainable.
- Added repository validation for Community Applications metadata and Docker
  template configuration.

### Changed

- Updated the NAS/Docker baseline to 1.1.0 and made routine NAS installation
  and updates pull the published image without touching persistent data.
- Documented why QNAP App Center is not used for the Docker edition: App Center
  catalogs native QPKG packages, while Container Station is QNAP's Compose UI.

## [0.2.0] - 2026-08-04

### Changed

- Renamed the public product to **TautWeekly for Plex** and standardized the
  repository, Pages site, documentation, UI, email, source, and release
  branding around `TautWeekly`.
- Renamed the PowerShell entry points to `TautWeekly.ps1`, Docker launchers to
  `tautweekly.sh` and `tautweekly-docker.ps1`, and release archives to the
  `TautWeekly-<platform>` convention.
- Renamed Docker services, images, internal application paths, operation
  locks, backups, and environment variables to the lowercase `tautweekly` or
  uppercase `TAUTWEEKLY_` convention.
- Moved repository and rendered documentation links to
  `sparkmoxie/TautWeekly` and `sparkmoxie.github.io/TautWeekly`.

### Migration

- Preserve private configuration and the Docker `data` directory, but replace
  program files with the 0.2.0 package and use the newly named launchers.
- Recreate Docker services with `docker compose up -d --build` after replacing
  the application files. Windows users should verify the scheduled-task name
  in `config.json` before reinstalling the schedule.

## [0.1.1] - 2026-08-03

### Fixed

- Preserved Docker dotfiles in ZIP release archives, including
  `.dockerignore`, `.env.example`, and `data/.keep`.
- Added a build-time ZIP payload parity check so archive creation fails if any
  staged source file is omitted.

## [0.1.0] - 2026-08-03

### Fixed

- Pointed the README documentation entry at the live Pages site, removed
  premature download links to an empty Releases page, and made current source
  locations explicit until the first version tag is published.
- Replaced user-facing links to HTML source blobs with rendered GitHub Pages
  URLs for the documentation home, all three platform walkthroughs, and the
  NAS / Docker Compose quick start.
- Made the Pages deployment follow the repository's current default launch
  branch and replaced a stale `blob/main` footer link with a default-branch
  (`HEAD`) URL.
- Preserved array semantics for exactly one adaptive movie or episode under
  Windows PowerShell 5.1 strict mode.
- Derived archive source-baseline metadata from each platform's shipped
  `VERSION.txt` instead of stale hard-coded values.

### Added

- Initial public, maintainable source tree for Windows, NAS/Docker, and macOS
  Docker Desktop.
- Sanitized configuration examples and repository-wide runtime-file guards.
- Interactive GitHub Pages documentation based on the supplied rich
  walkthroughs.
- Cross-platform validation, release packaging, checksums, Pages deployment,
  and tagged-release automation.
- Adaptive personal activity cards with posters, movie genres and ratings,
  episode metadata, and equal content-driven heights.
- A server-wide Binge Champion user award and counted Trending title feature.

### Changed

- Scheduled weekly mail now discloses the Binge Champion friendly name and
  winning aggregate; one-off welcome mail remains award-free.

### Source baselines

- Windows portable implementation: 1.6.11.
- NAS/Docker implementation: 1.0.7.
- macOS Docker Desktop implementation: 1.0.3.

These baseline numbers describe the imported platform distributions. Future
public GitHub releases use one repository-level semantic version.
