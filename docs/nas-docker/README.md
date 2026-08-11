# NAS / Docker installation

[Open the NAS/Docker/QNAP/Unraid Quickstart](https://sparkmoxie.github.io/TautWeekly/nas-docker/)
· [Install from the published Unraid Apps listing](https://ca.unraid.net/apps/tautweekly-for-plex-16l668j1jpt7jb)

This is one NAS / Docker distribution. It runs TautWeekly for Plex as a
dedicated service beside Tautulli and targets QNAP Container Station, Unraid,
general Linux Docker hosts, and Docker Desktop on x86-64 or ARM64. Docker
Compose is the deployment mechanism for manual installations, not a separate
edition or package.

Current source baseline: **1.1.0**.

## Requirements

- Docker Engine and Docker Compose v2, or a compatible vendor Compose UI.
- A non-root UID and GID that can write the project `data/` directory.
- Network access from the container to Tautulli and an SMTP STARTTLS endpoint.
- Network access from the container to Plex Media Server is recommended for
  complete movie RT critic/audience ratings, exact-episode IMDb ratings,
  backgrounds, and selected logos.
- A Tautulli API key.
- A trusted host port for the local preview service; default 8787.

## Install from Unraid Apps

In Unraid Community Applications, search for **TautWeekly for Plex**, review
the port and appdata path, and select **Install**. The maintained template is
[`templates/tautweekly.xml`](../../templates/tautweekly.xml) and pulls
`ghcr.io/sparkmoxie/tautweekly:latest` for amd64 or arm64 automatically.

After installation, open **Docker > TautWeekly for Plex > Console** and run:

> [!IMPORTANT]
> `./tautweekly.sh` is a host-side Compose wrapper shipped in the release
> archive. It does not exist inside the Unraid Apps container. Use the direct
> container commands below in the Unraid Console.

```bash
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Verify-Setup.ps1
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-User-Exclusions.ps1
/opt/tautweekly/bin/run-mode.sh ListUsers
/opt/tautweekly/bin/run-mode.sh PreviewAll USER_ID
/opt/tautweekly/bin/run-mode.sh SendTest USER_ID
```

Replace `USER_ID` with a numeric value printed by `ListUsers`. `ListUsers`
only displays the roster; it does not select or save a default user.

Open `http://UNRAID_HOST:8787/` to confirm the preview service and review its
first-run instructions. After `PreviewAll` completes, open
`http://UNRAID_HOST:8787/preview-all-00-INDEX.html` and review every state
before sending a TestEmail or enabling the schedule. Port 8787 is a private,
read-only preview viewer—not an administration Web UI. Never expose it to the
public internet.

Community Applications listings are moderated. The template can be audited
directly from its [raw URL](https://raw.githubusercontent.com/sparkmoxie/TautWeekly/main/templates/tautweekly.xml).
See the official [Unraid submission requirements](https://ca.unraid.net/submit/help)
and [repository XML format](https://ca.unraid.net/submit/help/repository-xml).

## Install on QNAP Container Station

QNAP's Docker-native path is **Container Station > Create Application**. Paste
[`compose.qnap.yaml`](../../platforms/nas-docker/compose.qnap.yaml), change the
timezone and non-root PUID/PGID, and confirm the host data path before creating
the application. QNAP documents Compose applications in Container Station;
App Center repositories distribute native QPKG applications instead, so this
Docker edition is not presented as a QPKG.

References: [QNAP Container Station application creation](https://docs.qnap.com/operating-system/qne-network/1.0.x/en-us/container-creation-1A95801A.html)
and [QNAP App Center repository settings](https://docs.qnap.com/operating-system/qts/5.0.x/en-us/app-center-settings-8C55F8A1.html).

The guided SSH installer remains available from the release archive:

```bash
./qnap-install.sh
```

## Install from a release on another Docker host

Download the latest
[`TautWeekly-nas-docker.tar.gz`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.tar.gz)
or [ZIP archive](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.zip),
then extract one format:

```bash
tar -xzf TautWeekly-nas-docker.tar.gz
cd TautWeekly-nas-docker
chmod +x qnap-install.sh tautweekly.sh container-update.sh app/*.sh app/bin/*.sh
```

For a general Docker host, use the portable Compose workflow:

```bash
cp .env.example .env
# Edit .env: timezone, UID/GID, preview bind, and preview URL.
docker compose pull
docker compose up -d
./tautweekly.sh setup
./tautweekly.sh verify
./tautweekly.sh manage-libraries
./tautweekly.sh exclude-users
```

Use a hostname reachable from inside the container, for example
`http://media.example.test:8181`. Do not use `127.0.0.1` for Tautulli unless it
runs in the same container, which is not the supported deployment model.

During setup, also enter a direct `PlexServerUrl` (normally port 32400) and an
administrator `PlexToken` for full newsletter fidelity. These are TautWeekly
settings stored privately in `/data/config.json`, but the URL is governed by
container networking: it must resolve and connect from inside TautWeekly.
`localhost`/`127.0.0.1` point to the TautWeekly container, not a separate Plex
container or NAS service. `verify` checks Plex `/identity` and authenticated
`/library/sections` without printing or placing the token in the URL. A
resolved but unusable connection fails verification; an unresolved pair emits
a Tautulli-only fallback warning.

## Safe acceptance sequence

For release-archive and manual Compose installations, run this sequence from
the extracted project directory on the Docker host, not inside the container:

```bash
./tautweekly.sh verify
./tautweekly.sh list-libraries
./tautweekly.sh manage-libraries
./tautweekly.sh list-users
./tautweekly.sh exclude-users
./tautweekly.sh preview-all USER_ID
./tautweekly.sh send-test-all USER_ID
./tautweekly.sh schedule-status
```

Replace `USER_ID` with a numeric value printed by `list-users`. The wrapper
can prompt when run interactively, but `list-users` does not persist a default.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. If the container timezone was changed, recreate or restart the
container before trusting the status.

During preview review, confirm the supplied animated movie/TV icons,
up-to-four most-watched movie and TV-show rows, duration-only Total Watched
card, anonymous Binge Champion duration plus nonzero movie/TV-show counts, gold winner
treatment, and Trending hero fallback. The TV stats card is absent when no
show was watched; TV-only release weeks retain their TV cards below the hero.

Only after the previews and controlled TestEmail messages are approved:

```bash
./tautweekly.sh schedule-enable
```

`welcome` and `send-all` target real Plex users and require interactive
confirmation.

## Manage user exclusions

Primary setup queries Tautulli after the URL and API key are entered. Select
comma-separated rows or ranges such as `2,4-6`; press Enter to keep the current
selection or type `none` to clear it. The stable IDs are saved in
`ExcludedUserIds`.

The selector joins Tautulli's bulk `get_user_names` and `get_users` responses
by stable ID instead of making one `get_user` request per row. A name-only row
remains selectable if its detailed bulk record is unavailable.

Run `./tautweekly.sh exclude-users` whenever the recipient policy changes.
Unraid Apps users can instead run this from the container Console:

```bash
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-User-Exclusions.ps1
```

The command changes only `ExcludedUserIds`; manually maintained
`ExcludedEmails` entries are preserved. Excluded users are skipped by the
scheduler and SendAll. Preview/TestEmail modes and the separately confirmed
one-off welcome remain explicit administrator tools. Treat the displayed
names and email addresses as private recipient data.

## Manage newsletter libraries

Primary setup discovers active Tautulli movie/TV libraries and stores the
chosen stable section IDs in `IncludedLibraryIds`. The scope is global and is
applied before releases, quiet mode, Trending, Binge Champion, and personal
statistics are calculated. Empty or absent IDs retain legacy all-library
behavior.

Run `./tautweekly.sh list-libraries` to inspect the scope and
`./tautweekly.sh manage-libraries` to replace it. Unraid Apps users can run the
same manager directly in the container Console:

```bash
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1
```

The manager accepts rows, ranges, `all`, or Enter to keep the selection and
backs up `/data/config.json` before writing. It does not alter SMTP, recipient,
or schedule settings.

## Networking

The default Compose file publishes container port 8080 as host port 8787. Set
`PREVIEW_BIND=127.0.0.1` for host-only access or bind to a trusted LAN interface
when remote preview access is required. Never port-forward this service to the
public internet.

When TautWeekly for Plex and Tautulli share a user-defined Docker network, a service URL
such as `http://tautulli:8181` is appropriate. Otherwise, use a DNS name the
container can resolve.

The server root always provides a small status and onboarding page. It does
not expose configuration, credentials, send controls, or scheduler controls.
Generated previews appear only after running `preview` or `preview-all`.

## First-run and connection troubleshooting

The only supported persistent configuration location inside the container is
`/data/config.json`. With the supplied Compose files it maps to
`./data/config.json` beside `compose.yaml`; with Unraid it maps into the
configured appdata directory. Editing `/opt/tautweekly/config.json` does not
configure the scheduler and that container-layer file would be lost on update.

If the browser reports **connection refused**:

```bash
./tautweekly.sh status
./tautweekly.sh logs
docker compose port tautweekly 8080
docker compose exec tautweekly tail -n 40 /data/logs/preview-server.log
```

Confirm the container is running and healthy, the published host port is the
one used in the browser, and a firewall is not blocking that host port. Use a
real host name or address in the browser—not Docker's `*:8787` port-listing
notation. The container now exits with a clear error if its preview server
cannot bind, allowing the restart policy and health status to expose the
failure.

If logs say they are waiting for `/data/config.json`, run
`./tautweekly.sh setup` from the extracted Compose directory. In Unraid, use
the exact `Setup-First.ps1` command shown above from the container Console.
Running the container alone does not authorize delivery: setup creates the
configuration, previews are generated on request, and scheduling stays off
until `schedule-enable` is confirmed.

## Persistent data

The relative bind mount `./data:/data` contains configuration, state, logs,
assets, generated output, and the bounded future-deletion cache at
`data/cache/deleted-items`. It is excluded from git and Docker build context.
The cache stores presentation metadata/posters only after an item is observed
live; it cannot recreate assets already discarded before v0.9.0.

Create a private backup with:

```bash
./tautweekly.sh backup
```

The backup contains credentials. Store it as securely as the live
configuration.

Image updates and recreation preserve `data/` and its cache. To clear cached
media without changing settings, stop the service and remove only
`data/cache/deleted-items`, then restart. During uninstall, retain or privately
back up `data/` unless configuration, state, output, cache entries, and backups
are all intentionally being removed.

## Container health

Release v0.5.3 and newer reports liveness from the service supervisor every
five seconds. Scheduled `SendAll` work may take several minutes without making
the container unhealthy. The preview root and supervisor heartbeat are hard
health requirements; missing decorative artwork emits a repair warning and is
handled by `./tautweekly.sh repair-assets`.

Use `docker inspect` to read the exact failed probe, `./tautweekly.sh logs` for
service output, and `./tautweekly.sh schedule-status` for separate scheduler
progress. NAS, QNAP, and general Compose deployments share this behavior.

## Updates and recovery

`ghcr.io/sparkmoxie/tautweekly:latest` advances only when a stable repository
release is tagged. The `edge` tag follows `main`; no packaged Compose or Unraid
default uses it.

For release-archive Compose and QNAP installations, checking and applying are
separate host actions:

```bash
./tautweekly.sh check-update  # pull/stage stable latest; do not restart
./tautweekly.sh backup        # optional private data backup
./tautweekly.sh update        # recreate, health/version check, auto-rollback
```

The update command refuses to start while the application operation lock is
busy, never deletes `data/`, forces Compose to use the pulled image instead of
rebuilding bundled source, and restores the prior image automatically when the
new container fails health verification. Backups contain credentials.

Unraid Apps installations do not receive the host wrapper and do not need an
in-container updater. Unraid's Apps Action Center reports an available update
when the configured `latest` digest changes; apply it from Unraid's Docker/Apps
controls. An optional automatic-update plugin may apply administrator-selected
updates, but unattended application is opt-in. Leave the template on `latest`,
not `edge`, unless deliberately testing unreleased code. After any update, run
the Console verification and controlled preview/TestEmail sequence again.

## Lifecycle commands

Run these from the extracted project directory on the Docker host. Unraid Apps
users should use Unraid's Docker controls for status, logs, restart, and image
updates; application commands use the direct Console forms shown above.

```bash
./tautweekly.sh status
./tautweekly.sh logs
./tautweekly.sh restart
./tautweekly.sh check-update
./tautweekly.sh update
./tautweekly.sh schedule-disable
docker compose down
```

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
