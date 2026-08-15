<div align="center">

<img src="assets/branding/tautweekly-logo-256.png" alt="TautWeekly detailed popcorn TW logo" width="220">

# TautWeekly for Plex

**A portable, preview-first weekly Plex activity newsletter powered by Tautulli.**

[![CI](https://github.com/sparkmoxie/TautWeekly/actions/workflows/ci.yml/badge.svg)](https://github.com/sparkmoxie/TautWeekly/actions/workflows/ci.yml)
[![Pages](https://github.com/sparkmoxie/TautWeekly/actions/workflows/pages.yml/badge.svg)](https://sparkmoxie.github.io/TautWeekly/)
[![License: MIT](https://img.shields.io/badge/code%20license-MIT-e5a00d.svg)](LICENSE)
![Windows](https://img.shields.io/badge/Windows-PowerShell%205.1-0078d4?logo=windows)
![NAS](https://img.shields.io/badge/NAS-Docker%20Compose-2496ed?logo=docker)
[![Unraid Community Apps](https://img.shields.io/badge/Unraid-Community%20Apps-f15a2c?logo=unraid)](https://sparkmoxie.github.io/TautWeekly/nas-docker/#unraid)
![Container](https://img.shields.io/badge/GHCR-amd64%20%7C%20arm64-2496ed?logo=docker)
![macOS](https://img.shields.io/badge/macOS-Docker%20Desktop-000000?logo=apple)
![Linux](https://img.shields.io/badge/Linux-native%20systemd-4d8f28?logo=linux)
![FreeBSD](https://img.shields.io/badge/FreeBSD-Podman%20beta-b7292f?logo=freebsd)

Turn Plex activity into polished new-release, personal-recap, welcome, quiet-week,
and milestone emails. Preview locally, send controlled tests, then schedule delivery.

[TautWeekly Quickstart](https://sparkmoxie.github.io/TautWeekly/) ·
[GUI Preview](https://sparkmoxie.github.io/TautWeekly/gui-preview/) ·
[Preview the email states](https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html) ·
[Download the latest release](https://github.com/sparkmoxie/TautWeekly/releases/latest) ·
[Read the documentation](docs/README.md)

</div>

> [!IMPORTANT]
> TautWeekly handles private Plex/Tautulli activity and mail credentials. Preview
> first, use a controlled test recipient, and never commit or publicly share live
> configuration, tokens, logs, previews, newsletters, state, or backups. See
> [Security and hardening](docs/SECURITY.md).

## Choose a platform

| Platform | Best fit | Start here |
|---|---|---|
| Windows Manager | Always-on Windows 10/11 host | [Windows Quickstart](https://sparkmoxie.github.io/TautWeekly/windows/) · [Documentation](docs/windows/README.md) · [Download Setup](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe) |
| NAS / Docker | QNAP, Unraid, Linux NAS, or another Docker host | [NAS/Docker/QNAP/Unraid Quickstart](https://sparkmoxie.github.io/TautWeekly/nas-docker/) · [Unraid Apps](https://ca.unraid.net/apps/tautweekly-for-plex-16l668j1jpt7jb) · [Documentation](docs/nas-docker/README.md) · [Download](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.tar.gz) |
| macOS | Docker Desktop on Intel or Apple silicon | [macOS Quickstart](https://sparkmoxie.github.io/TautWeekly/mac/) · [Documentation](docs/mac/README.md) · [Download](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-docker.tar.gz) |
| Native Linux | Current Ubuntu, Debian, or RHEL host with systemd | [Native Linux Quickstart](https://sparkmoxie.github.io/TautWeekly/linux/) · [Documentation](docs/linux/README.md) · [Download](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-linux.tar.gz) |
| FreeBSD / Podman **beta** | FreeBSD 15.1+ amd64 host | [FreeBSD Podman Quickstart](https://sparkmoxie.github.io/TautWeekly/freebsd/) · [Documentation](docs/freebsd/README.md) · [Download](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-freebsd-podman.tar.gz) |

### Windows Manager: the normal setup path

Windows users should download and run
[`TautWeekly-Setup.exe`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe),
choose a permanent application folder, and complete setup in the local Manager.
The Manager opens on the Dashboard; a new installation shows a blue **First time
setup** card that leads to **Config**. **Validate, save, and verify** then loads
the available libraries and users, checks Tautulli and direct Plex, runs a
non-sending SMTP preflight, and prepares six local previews when metadata is
ready. Those four results persist and are summarized on the Dashboard.

Windows trusted-local access requires no first-run pairing token. If other
people use the same Windows account, an optional password lock can be enabled,
changed, disabled, or recovered under **Settings**. Install or refresh the
weekly Windows task from **Schedule** only after reviewing local previews and a
controlled six-message `TestEmail` delivery. The numbered BAT launchers remain
available only for portable recovery and advanced troubleshooting.

## Current newsletter behavior

- New movie and TV additions with artwork, summaries, genres, ratings, and
  episode details when available.
- A private personal recap with watch time and most-watched movies and shows.
- Adaptive **HOT NEW RELEASE** and **TRENDING THIS WEEK** highlights.
- A privacy-preserving, server-wide Binge Champion award.
- Welcome, active-week, quiet-week, and milestone newsletter layouts.
- Browser previews and controlled TestEmail delivery before scheduling.

Tautulli is the required activity source. Optional direct Plex access enriches
ratings and artwork when the server exposes them. Detailed provider, privacy,
cache, and rendering rules live in the references linked below.

## Get started

1. Choose your platform above and open its interactive Quickstart.
2. Install the latest stable package and complete the guided setup.
3. Run verification, inspect a private preview, and send a controlled TestEmail.
4. Enable scheduled delivery only after the result is correct.

The platform guides contain the exact requirements, commands, metadata-readiness
sequence, update and rollback behavior, network guidance, and troubleshooting.

## Quick links

- [Interactive Quickstart home](https://sparkmoxie.github.io/TautWeekly/)
- [GUI Preview](https://sparkmoxie.github.io/TautWeekly/gui-preview/)
- [Email States Preview](https://sparkmoxie.github.io/TautWeekly/examples/preview-all-00-INDEX.html)
- [Latest release and notes](https://github.com/sparkmoxie/TautWeekly/releases/latest)
- [SHA-256 checksums](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/SHA256SUMS.txt)
- [Configuration reference](docs/CONFIGURATION.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Security and hardening](docs/SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md) · [Contributors](CONTRIBUTORS.md)

## License and affiliation

TautWeekly for Plex source code, documentation, and bundled custom artwork are
licensed under the [MIT License](LICENSE). Asset provenance is recorded in
[Third-party notices](THIRD_PARTY_NOTICES.md).

TautWeekly for Plex is an independent community project. It is not affiliated
with, endorsed by, or sponsored by Plex, Tautulli, or the other platforms and
providers it integrates with. All product names and marks belong to their
respective owners.
