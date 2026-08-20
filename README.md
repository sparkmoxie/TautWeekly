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

Every maintained Manager uses **Settings > Updates** as the primary status
source. It distinguishes the running application/Manager, release package, and
container image where those versions are knowable; reports the stable channel,
latest verified release, last successful check, last sanitized failure, and
legacy or mismatched host adapters; and links to the release notes. An
authenticated Manager session renders cached status first, then makes one
non-blocking bounded check only when the last successful result is missing or
at least 24 hours old and retry backoff permits. A successful automatic or
manual result is reused for five minutes before another explicit refresh is
allowed. **Check now** remains available after that guard, while navigation,
Dashboard rendering, and health
endpoints remain offline-capable. A purple header notification links to this
status view only when a successful check validates a newer running-application
version; the larger status card attracts attention for every non-current state,
while the existing green **Current** chip remains unchanged. Neither cue installs
an update. Only Windows can start an installation from the GUI, using the
existing verified updater and Windows elevation. All other platforms show the
exact host-owned command or native update flow without giving the web process
Docker, root, Podman, systemd, rc.d, or package-file authority.

Every package also has an optional **Settings > Tailscale** card for private
HTTPS remote administration. Windows and native Linux can create and verify a
fixed loopback Serve route through narrow package helpers; macOS, FreeBSD,
QNAP, Unraid, and compatible Docker/NAS hosts create the private route through
their host client or the shipped optional userspace sidecar, then save only its
exact `.ts.net` address. For optional mobile use, install and sign in to
Tailscale on the phone or tablet, then open that private address; it is not a
clientless public URL. Funnel is never required or enabled by TautWeekly.
Non-Windows Manager passwords remain required, the Windows lock remains
optional, and every remote login has full administration rather than a
read-only role.

### Windows Manager: the normal setup path

Windows users should download and run
[`TautWeekly-Setup.exe`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe),
choose a permanent application folder, and complete setup in the local Manager.
The Manager opens on the Dashboard; a new installation shows a blue **First time
setup** card that leads to **Config**. **Validate, save, and verify** then loads
the available libraries and users, checks Tautulli and direct Plex, runs a
non-sending SMTP preflight, and prepares six local previews when metadata is
ready. Those four results persist and are summarized on the Dashboard.

While the interactive Windows Manager is running, the TautWeekly icon remains
in the notification area. Left-click opens the existing Dashboard; the native
right-click menu shows current Manager health, lets that status row open or
focus the Dashboard, and provides a graceful Exit.
Settings can start the Manager silently for the current user at sign-in and,
optionally, open the Dashboard once it is ready. Exiting the Manager does not
disable the independent weekly Scheduled Task.

Windows trusted-local access requires no first-run pairing token. If other
people use the same Windows account, an optional password lock can be enabled,
changed, disabled, or recovered under **Settings**. Install or refresh the
weekly Windows task from **Schedule** only after reviewing local previews and a
controlled six-message `TestEmail` delivery. The numbered BAT launchers remain
available only for portable recovery and advanced troubleshooting.

### NAS / Docker Manager: one secure core

QNAP Container Station, Unraid Apps, generic Compose, and compatible Docker
hosts use the same authenticated Manager and persistent `/data` boundary. Start
the host-owned container, run the documented `manager-bootstrap` command, open
the mapped Manager URL, pair once, and create a unique administrator password.
There is no default password, and the one-time token is never printed in normal
container logs. Complete Config, verification, six previews, and TestEmail in
the GUI before enabling the embedded schedule.

For release-archive Compose and QNAP installs, back up `/data`, then run
`./tautweekly.sh check-update` and `./tautweekly.sh update`. The wrapper verifies
the stable archive checksum and its internal file manifest, refreshes the host
Compose/wrapper package, preserves `.env` and `/data`, recreates the service,
checks health/version, and restores both host files and the prior image on
failure. Unraid keeps its Apps-owned update lifecycle; existing installs should
compare/apply the current template so host hardening and compatibility variables
advance with the image. Reinstall, rollback, or Manager access recovery preserves
the persistent volume unless the administrator separately chooses to delete it.
Use **Settings > Updates** before and after that host action; Unraid directs to
Docker/Apps, QNAP to Container Station plus the verified SSH wrapper, and other
compatible Docker hosts to their original Compose/deployment tool.

### macOS Manager: Docker Desktop, tailored for Mac

The Intel and Apple-silicon Mac archive includes the same authenticated Manager
core with a distinct macOS Docker Desktop capability profile. The installer
detects the current Mac UID/GID, keeps the Manager on `127.0.0.1:8787` by
default, and preserves `.env`, `data/config.json`, schedules, output, and Manager
access state. Run `./tautweekly.sh manager-bootstrap`, open the Manager, create a
unique administrator password, then complete Config, verification, six previews,
TestEmail, and Schedule in the GUI. No tray icon, Windows startup/task controls,
or NAS lifecycle language is exposed.

Mac updates remain host-owned: back up `data/`, then run
`./tautweekly.sh update`. The wrapper downloads and verifies the newer stable
Mac archive and internal manifest, preserves `.env` and `data/`, builds the
correct amd64 or arm64 Manager image, refuses a busy renderer operation,
verifies version and health, and restores prior package files and image on
rollback. Sign back in and repeat the Manager health, Config, preview, and
TestEmail acceptance checks.

### Native Linux Manager: GUI-first systemd service

The native Linux archive now includes amd64 and arm64 Manager binaries. The
installer selects the host architecture, starts an authenticated loopback-only
systemd service, and keeps private state under `/var/lib/tautweekly`. Use an SSH
tunnel to port 8788, run `sudo tautweekly manager-bootstrap`, then complete the
same guided GUI workflow. The `tautweekly` command remains available for
recovery and expert operations.

Linux updates are explicit: run `tautweekly check-update`, back up private data,
then run `sudo tautweekly update`. The host downloads and verifies the stable
archive plus its internal manifest before the installer backs up
`/opt/tautweekly`, preserves `/var/lib/tautweekly`, waits for an active delivery
during graceful service shutdown, and verifies service recovery. Sign back into
the Manager and rerun verification, previews, and TestEmail after upgrading.

### FreeBSD Podman Manager: beta host adapter

The FreeBSD package runs the same authenticated OCI Manager through Podman and
keeps its rc.d-owned port on `127.0.0.1:8787` by default. After installation,
run `sudo tautweekly manager-bootstrap`, use the documented SSH tunnel, and
complete Config, Verify, PreviewAll, TestEmail, and Schedule in the GUI. The
wrapper also provides narrow Manager access recovery, verified host-package and image updates,
health-checked rollback, and private backups. Normal rc.d stop/restart grants
an already-running newsletter delivery up to 30 minutes to drain. Physical
FreeBSD/Podman behavior remains a beta acceptance gap because hosted CI cannot
boot that host combination.

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
