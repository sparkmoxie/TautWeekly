# Changelog

All notable public changes to TautWeekly for Plex will be documented here. The project
uses [Semantic Versioning](https://semver.org/) for GitHub releases and follows
the structure of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
