# NAS / Docker installation

[Open the NAS/Docker/QNAP/Unraid Quickstart](https://sparkmoxie.github.io/TautWeekly/nas-docker/)
· [Install from the published Unraid Apps listing](https://ca.unraid.net/apps/tautweekly-for-plex-16l668j1jpt7jb)

This is one NAS / Docker distribution. It runs TautWeekly for Plex as a
dedicated service beside Tautulli and targets QNAP Container Station, Unraid,
general Linux Docker hosts, and Docker Desktop on x86-64 or ARM64. Docker
Compose is the deployment mechanism for manual installations, not a separate
edition or package.

Current source baseline: **1.4.1**.

> [!IMPORTANT]
> The authenticated Manager is the setup source for every target in this
> distribution. Use its **Config**, **Verify**, **Previews**, **Operations**,
> and **Schedule** pages for normal administration. Host/container commands
> are limited to install, bootstrap, lifecycle, update, backup, recovery, and
> explicit expert fallbacks.

## Requirements

- Docker Engine and Docker Compose v2, or a compatible vendor Compose UI.
- A non-root UID and GID that can write the project `data/` directory.
- Network access from the container to Tautulli and an SMTP STARTTLS endpoint.
- Network access from the container to Plex Media Server is recommended for
  complete movie RT critic/audience ratings, exact-episode IMDb/RT ratings,
  backgrounds, and selected logos.
- A Tautulli API key.
- A trusted-LAN host port for the authenticated Manager; default 8787.
- A browser that can reach the NAS by IP address, or an explicit
  `MANAGER_ALLOWED_HOSTS` entry when a DNS name or reverse proxy is used.

## Required Manager authentication

The NAS Manager never has a default password. On first start it creates a
random, one-time pairing token in private `/data/manager` storage. The token is
not printed to container logs. Retrieve it only through an explicit local
administrator command:

```bash
./tautweekly.sh manager-bootstrap
```

Open `http://NAS_IP:8787/`, enter that token, and create an administrator
password of at least eight characters. The Manager stores only a salted,
iterated password hash; sessions are in memory, expire after eight hours, use
HttpOnly SameSite=Strict cookies, and require a per-session CSRF token for
changes. Five failed authentication attempts within five minutes temporarily
limit further attempts. Restarting the Manager signs out all browsers but does
not change the password, newsletter schedule, or a newsletter already running.

## Install from Unraid Apps

In Unraid Community Applications, search for **TautWeekly for Plex**, review
the port and appdata path, and select **Install**. The maintained template is
[`templates/tautweekly.xml`](../../templates/tautweekly.xml) and pulls
`ghcr.io/sparkmoxie/tautweekly:latest` for amd64 or arm64 automatically.

After installation, open **Docker > TautWeekly for Plex > Console** and run:

> [!IMPORTANT]
> `./tautweekly.sh` is a host-side Compose wrapper shipped in the release
> archive. It does not exist inside the Unraid Apps container. Use the direct
> container launchers below in the Unraid Console. Do not invoke the
> PowerShell files directly: Docker Console/exec sessions begin as root, while
> the launcher repairs legacy root-owned `/data` entries and then uses the
> configured non-root PUID/PGID.

```bash
/opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager \
  access-bootstrap --data-dir /data/manager
```

Open `http://UNRAID_HOST:8787/`, pair the browser, and use the guided Manager
to configure, verify, generate previews, send controlled TestEmail messages,
and enable the embedded schedule. The legacy Console helpers remain available
for recovery, but they are no longer the normal setup path. Never port-forward
plain HTTP Manager access to the public internet.

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

A native QPKG is not warranted for this delivery: it would add a second
installer, signing and App Center review obligations, and hardware-specific
lifecycle code without improving the Docker-native runtime. It may be scoped
separately only with QNAP hardware and store-submission validation.

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
chmod +x qnap-install.sh tautweekly.sh container-update.sh package-update.sh app/*.sh app/bin/*.sh
```

For a general Docker host, use the portable Compose workflow:

```bash
cp .env.example .env
# Edit .env: timezone, UID/GID, Manager bind, URL, and optional allowed hosts.
docker compose pull
docker compose up -d
./tautweekly.sh manager-bootstrap
```

Open `http://NAS_IP:8787/`, pair the browser, and complete guided setup. A DNS
name such as `tautweekly.example.test` must be listed exactly in
`MANAGER_ALLOWED_HOSTS`; IP-literal access needs no entry. Do not add schemes,
paths, ports, or wildcards.

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
Verification proves reachability and authentication, not that every item has
every provider score. The renderer explicitly requests Plex's optional
`Rating` element so available movie RT pairs and exact-episode IMDb/RT values are not
hidden by a selected IMDb/TMDB fallback. If JSON lacks movie RT or
exact-episode provider entries, the renderer retries the same authenticated local
item as XML and reads only provider-labelled `Rating` elements.
For intended movie RT output, set every applicable Plex Movie library's
**Edit → Advanced → Ratings Source** to **Rotten Tomatoes**. This is a
library-wide Plex choice, not a TautWeekly setting; leave IMDb/TMDB selected if
that fallback is intentional.

## Metadata readiness before acceptance

After first setup, after changing a Plex metadata agent or Ratings Source, and
after a ratings/artwork recovery update when upstream data may be stale:

1. Confirm **Edit → Advanced → Ratings Source** in every included Plex Movie
   library.
2. Run Plex **Manage Library → Refresh All Metadata** for every included movie
   and TV library, then wait for all refreshes to finish.
3. In Tautulli, open each same **Library → Media Info** tab, select
   **Refresh media info**, and wait. The current control is per library, so
   repeat it for every included section.
4. Run `verify`, PreviewAll, and TestEmail only after both refresh stages
   complete.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music/photo libraries for TautWeekly.
Tautulli's [section-specific media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require a full refresh when
current output already renders correctly.

## Safe acceptance sequence

In the Manager, complete Config and choose **Validate, save, and verify**.
Review the library scope and delivery exclusions, generate all six previews,
send only to TestEmail, and inspect **Schedule**. Before enabling delivery,
confirm the configured timezone, scheduler timezone, and scheduler-local time
agree. Recreate or restart the container after changing its timezone.

The following release-archive commands are expert/recovery fallbacks. Run them
from the extracted project directory on the Docker host, not in the container:

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

During preview review, confirm the supplied animated movie/TV icons,
up-to-four most-watched movie and TV-show rows, duration-only Total Watched
card, anonymous Binge Champion duration plus nonzero movie/TV-show counts, gold winner
treatment, and Trending hero fallback. The TV stats card is absent when no
show was watched; TV-only release weeks retain their TV cards below the hero.

Only after the previews and controlled TestEmail messages are approved, enable
future delivery on Manager **Schedule**. The expert fallback is:

```bash
./tautweekly.sh schedule-enable
```

`welcome` and `send-all` target real Plex users and require interactive
confirmation.

## Manage user exclusions

Manager Config queries Tautulli after the URL and API key are entered and
presents the delivery exclusions without exposing email addresses in browser
diagnostics. Stable IDs are saved in `ExcludedUserIds`.

The selector joins Tautulli's bulk `get_user_names` and `get_users` responses
by stable ID instead of making one `get_user` request per row. A name-only row
remains selectable if its detailed bulk record is unavailable.

Normally change the recipient policy in Manager Config. The
`./tautweekly.sh exclude-users` command is an expert/recovery fallback. Unraid
Apps users can invoke the equivalent fallback from the container Console:

```bash
/opt/tautweekly/bin/run-script.sh Manage-User-Exclusions.ps1
```

The command changes only `ExcludedUserIds`; manually maintained
`ExcludedEmails` entries are preserved. Excluded users are skipped by the
scheduler and SendAll. Preview/TestEmail modes and the separately confirmed
one-off welcome remain explicit administrator tools. Treat the displayed
names and email addresses as private recipient data.

## Manage newsletter libraries

Manager Config discovers active Tautulli movie/TV libraries and stores the
chosen stable section IDs in `IncludedLibraryIds`. The scope is global and is
applied before releases, quiet mode, Trending, Binge Champion, and personal
statistics are calculated. Empty or absent IDs retain legacy all-library
behavior.

Normally inspect and replace this scope in Manager Config. The
`list-libraries` and `manage-libraries` commands are expert/recovery fallbacks.
Unraid Apps users can invoke the equivalent fallback in the container Console:

```bash
/opt/tautweekly/bin/run-script.sh Manage-Library-Selection.ps1
```

The manager accepts rows, ranges, `all`, or Enter to keep the selection and
backs up `/data/config.json` before writing. It does not alter SMTP, recipient,
or schedule settings.

## Networking

The default Compose file publishes container port 8080 as host port 8787. Set
`PREVIEW_BIND=127.0.0.1` for host-only access or bind to a trusted LAN interface
when LAN Manager access is required. IP-literal Host headers are accepted in
NAS mode. DNS names are rejected unless listed exactly, comma-separated, in
`MANAGER_ALLOWED_HOSTS`; this keeps the default usable with dynamic NAS
addresses while resisting DNS-rebinding through attacker-controlled names.
The Manager ignores `Forwarded` and `X-Forwarded-*` headers and never infers
trust, client identity, host, or TLS from them.

For remote access, place the Manager behind a reverse proxy that terminates
TLS, preserves the original `Host` header, and does not publish the port
directly. Add the public DNS name to `MANAGER_ALLOWED_HOSTS`, verify HTTPS end
to end, then set `MANAGER_SECURE_COOKIES=true` and recreate the container.
That setting forces Secure cookies and HSTS; enabling it on a plain HTTP URL
makes login intentionally fail. TautWeekly does not provision certificates or
declare any proxy trusted. Prefer a VPN for administration and never expose
plain HTTP to the public internet.

When TautWeekly for Plex and Tautulli share a user-defined Docker network, a service URL
such as `http://tautulli:8181` is appropriate. Otherwise, use a DNS name the
container can resolve.

Only `GET /health/live`, the minimal first-run state, and the pairing/login
endpoints are unauthenticated. Configuration, diagnostics, previews, send
controls, scheduler controls, and all other status require an authenticated
session. Liveness never contacts Tautulli, Plex, SMTP, or another network
service.

The supplied Compose definitions run with a read-only image filesystem, a
bounded in-memory `/tmp`, `no-new-privileges`, and all Linux capabilities
dropped except the narrow ownership and UID/GID transition set needed by the
root-only entrypoint. The Manager, scheduler, and renderer then run as the
configured non-root numeric identity. These fields follow Docker's official
[Compose service specification](https://docs.docker.com/reference/compose-file/services/);
vendor Compose screens may expose the same controls under different labels.

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
docker compose exec tautweekly tail -n 40 /data/logs/manager.log
```

Confirm the container is running and healthy, the published host port is the
one used in the browser, and a firewall is not blocking that host port. Use a
real host name or address in the browser—not Docker's `*:8787` port-listing
notation. The container exits with a clear error if its Manager
cannot bind, allowing the restart policy and health status to expose the
failure.

If the Manager requests a pairing token, run `manager-bootstrap`; do not search
logs because the token is intentionally absent. Running the container alone
does not authorize delivery: guided setup creates `/data/config.json`, preview
and email operations remain explicit, and scheduling stays disabled until the
administrator enables it.

## Persistent data

The relative bind mount `./data:/data` contains configuration, Manager
credentials and sanitized history under `data/manager`, state, logs, private
backups, assets, generated output, and the bounded future-deletion cache at
`data/cache/deleted-items`. It is excluded from git and Docker build context.
The cache stores presentation metadata/posters only after an item is observed
live; it cannot recreate assets already discarded before v0.9.0.

Create a private backup with:

```bash
./tautweekly.sh backup
```

The backup contains credentials. Store it as securely as the live
configuration.

Named volumes are also supported, but the same `/data` contract applies. Never
mount configuration over `/opt/tautweekly`; the image may be treated as
read-only and that layer is disposable. Image updates, recreation, and
reinstall preserve `data/` and its cache. To clear cached
media without changing settings, stop the service and remove only
`data/cache/deleted-items`, then restart. During uninstall, retain or privately
back up `data/` unless configuration, Manager access, state, output, cache
entries, and backups are all intentionally being removed. `docker compose
down` does not delete a bind mount; do not add `--volumes` when a named volume
must be retained.

When changing PUID/PGID, stop the container, back up `/data`, change the values,
and start it once. The root-only entrypoint adjusts the dedicated data tree and
drops to the configured non-root identity before the Manager, scheduler, or
renderer starts. It refuses UID or GID 0 and does not follow symlinks outside
the data mount during legacy ownership recovery. A host that denies ownership
changes must be repaired by its administrator before startup; TautWeekly never
falls back to running the application as root.

## Container health

Release v0.5.3 and newer reports liveness from the service supervisor every
five seconds. Scheduled `SendAll` work may take several minutes without making
the container unhealthy. Minimal Manager liveness and the supervisor heartbeat
are hard health requirements; external dependency outages remain application
status and never trigger a restart loop.

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
./tautweekly.sh check-update  # compare verified host package and image; do not restart
./tautweekly.sh backup        # optional private data backup
./tautweekly.sh update        # verify/sync host package, recreate, health-check, rollback
```

`check-update` reads the installed release metadata, checks the latest stable
GitHub release, validates current release-owned files, and performs only the
image pull used for a read-only digest comparison. `update` downloads the
matching TAR package and `SHA256SUMS.txt`, verifies the published SHA-256 and the
archive's `RELEASE-FILES.txt`, replaces only release-owned host files, and
preserves `.env`, `data/`, named volumes, and unrelated administrator files.
It also removes only retired files owned by the prior release manifest.

The update command refuses to start while the application operation lock is
busy, never deletes `data/`, forces Compose to use the pulled image instead of
rebuilding bundled source, and restores both the prior host package and image
automatically when copying, recreation, version, or health verification fails.
The supplied Compose file grants a
29-minute delivery drain inside a 30-minute stop grace period: Manager HTTP
access closes first, then shutdown waits on the shared newsletter operation
lock before stopping the independent scheduler. A NAS UI or engine that forces
a shorter stop timeout can still terminate container processes; check for an
idle Manager operation before applying updates on such hosts. Backups contain
credentials.

Unraid Apps installations do not receive the host wrapper and do not need an
in-container updater. Unraid's Apps Action Center reports an available update
when the configured `latest` digest changes; apply it from Unraid's Docker/Apps
controls. An optional automatic-update plugin may apply administrator-selected
updates, but unattended application is opt-in. Leave the template on `latest`,
not `edge`, unless deliberately testing unreleased code. After any update, run
the Manager verification and controlled preview/TestEmail sequence again. If
the update addresses missing ratings/artwork or output remains stale, complete
metadata readiness before those checks. For an installation saved from an older
template, open **Docker > TautWeekly for Plex > Edit**, compare/apply the current
Community Apps template, and confirm its stop timeout, security options, and
advanced `Host Adapter API` value are present before applying the image update.
Keep the existing appdata path, port, PUID, PGID, timezone, and Manager policy;
do not delete or replace appdata during this migration. A startup warning that
the host adapter is `legacy` means the saved template still needs this refresh.

Manager **Config > Configuration backups** lists metadata only. Every package
GUI can restore a selected backup or permanently delete one individual backup
after a separate **Confirm delete** action. Deletion does not change the current
`config.json`, is authenticated and CSRF-protected, and cannot be undone; keep
any required private retention copy first.

### Password recovery

Compose installations can reset only Manager authentication:

```bash
./tautweekly.sh manager-reset-access
./tautweekly.sh manager-bootstrap
```

For Unraid, open the Console of the running container or use an equivalent
local `docker exec`, run the following recovery command, then restart the
container and retrieve the new bootstrap token:

```bash
/opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager \
  access-recover --data-dir /data/manager --confirm
```

Recovery removes only Manager authentication files. It preserves
`config.json`, SMTP/Plex/Tautulli secrets, schedule settings, newsletter state,
previews, cache, backups, and sanitized operation history. Restart is required
to invalidate in-memory sessions and create the new one-time token. Never
delete all of `/data` merely to recover Manager access.

### Rollback and incompatible data

Before an upgrade, keep a private `/data` backup and record the current image
digest. The host wrapper automatically returns to the prior image when the new
container fails health checks. If a future package reports an unsupported data
schema, stop it, preserve the failed `/data` tree, restore the matching private
backup, and recreate with the recorded image digest. Do not start an older
image repeatedly against newer data or copy only `config.json`; Manager access,
schedule guards, and recipient state are part of the durable installation.

## Lifecycle commands

Run these from the extracted project directory on the Docker host. Unraid Apps
users should use Unraid's Docker controls for status, logs, restart, and image
updates; application commands use the direct Console forms shown above.

```bash
./tautweekly.sh status
./tautweekly.sh logs
./tautweekly.sh restart
./tautweekly.sh manager-bootstrap
./tautweekly.sh manager-reset-access
./tautweekly.sh check-update
./tautweekly.sh update
./tautweekly.sh schedule-disable
docker compose down
```

`restart`, `down`, NAS power-off, and image replacement are host lifecycle
actions, not Manager buttons. Disabling the schedule prevents future starts
but never cancels a delivery already running. For uninstall, first disable the
schedule, confirm no operation is active, stop/remove the container, and retain
or back up the bind mount or named volume. Delete `/data` only as a separate,
explicit data-destruction decision after verifying the backup; reinstalling
against retained `/data` restores configuration, Manager credentials, schedule,
and state.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
