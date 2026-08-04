# macOS Docker Desktop installation

[Open the rendered interactive macOS walkthrough](https://sparkmoxie.github.io/TautWeekly/mac/)

The macOS distribution runs the PowerShell newsletter engine in Docker Desktop
and provides Mac-native setup and preview helpers.

Current source baseline: **1.0.3**.

## Requirements

- An Intel or Apple silicon Mac.
- Docker Desktop with Docker Compose available in Terminal.
- Network access from Docker to Tautulli and an SMTP STARTTLS endpoint.
- A Tautulli API key.
- A permanent project directory writable by the current macOS user.

## Install

1. Download and extract
   [`TautWeekly-mac-docker.tar.gz`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-docker.tar.gz)
   or the equivalent [ZIP archive](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-mac-docker.zip).
2. Open Terminal in the extracted directory.
3. Make the launchers executable and start the guided installer:

```bash
chmod +x INSTALL-MAC.command mac-install.sh tautweekly.sh app/*.sh app/bin/*.sh
./mac-install.sh
```

Alternatively, double-click `INSTALL-MAC.command` after granting it execute
permission.

The installer detects the current UID/GID, creates a private `.env`, builds the
container, runs interactive setup, and verifies the result. Existing `.env` and
`data/config.json` files are preserved unless you explicitly replace them.

## Service connectivity

For software running directly on the Mac, Docker Desktop exposes the host as
`host.docker.internal`:

```text
http://host.docker.internal:8181   # Tautulli
http://host.docker.internal:32400  # optional direct Plex URL
```

For another server, use a resolvable hostname such as
`http://media.example.test:8181`. For a Tautulli container on the same
user-defined Docker network, use its service name.

## Safe acceptance sequence

```bash
./tautweekly.sh verify
./tautweekly.sh list-users
./tautweekly.sh exclude-users
./tautweekly.sh preview-all
./tautweekly.sh open-preview
./tautweekly.sh send-test-all
./tautweekly.sh schedule-status
```

During preview review, confirm the adaptive one-item cards, movie genres,
anonymous Binge Champion movie/TV/time aggregate, gold winner treatment, and
counted Trending section.

Enable automation only after reviewing browser previews and TestEmail messages:

```bash
./tautweekly.sh schedule-enable
```

The macOS Compose default binds previews to `127.0.0.1`. Keep that default
unless trusted-LAN access is intentional.

## Manage user exclusions

During primary setup, the wizard queries Tautulli and lets you select numbered
users or ranges such as `2,4-6`. Press Enter to keep the current selection or
type `none` to clear it. Run `./tautweekly.sh exclude-users` later to update
only the stable IDs in `ExcludedUserIds`; existing `ExcludedEmails` values are
left unchanged.

Excluded users are skipped by automatic delivery and SendAll. Preview and
TestEmail modes can still use them for safe rendering checks, and the one-off
welcome remains a separately confirmed administrator action. Do not share the
selector's names or email addresses publicly.

## Data and updates

Private runtime data lives in `data/`. Back it up with
`./tautweekly.sh backup`, keep the archive private, and update the image with
`./tautweekly.sh update`. Re-run verification and controlled previews after an
update.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
