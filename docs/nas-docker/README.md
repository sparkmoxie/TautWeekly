# NAS / Docker installation

[Open the NAS/Docker/QNAP/Unraid Quickstart](https://sparkmoxie.github.io/TautWeekly/nas-docker/)
· [Install from the published Unraid Apps listing](https://ca.unraid.net/apps/tautweekly-for-plex-16l668j1jpt7jb)

TautWeekly publishes one shared `ghcr.io/sparkmoxie/tautweekly` OCI image for
QNAP Container Station, Unraid, general Linux Docker hosts, Docker Desktop,
FreeBSD/Podman, and compatible x86-64 or ARM64 container systems. The explicit
`server`, `unraid`, or `desktop` runtime profile preserves each host's Manager,
network, persistence, permission, health, scheduling, and lifecycle contract
without duplicating the application payload.

Current source baseline: **1.6.0**.

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
[`templates/tautweekly.xml`](../../templates/tautweekly.xml), selects the
validated `unraid` profile, and pulls `ghcr.io/sparkmoxie/tautweekly:latest`
for amd64 or arm64. This mutable reference is an Unraid Apps lifecycle
exception, not the recommended CI/CD reference; review the digest change in
Docker/Apps before applying it.

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

## Preferred no-clone Compose install

Download and verify the release's standalone server Compose asset. It pins the
full semantic version, explicitly selects `TAUTWEEKLY_RUNTIME_PROFILE=server`,
uses the `container-compose` package identity, exposes the Manager on the
trusted LAN by default, and bind-mounts `./data` at `/data`:

```bash
mkdir -p TautWeekly && cd TautWeekly
TAUTWEEKLY_VERSION=0.23.0
curl -fLO "https://github.com/sparkmoxie/TautWeekly/releases/download/v${TAUTWEEKLY_VERSION}/TautWeekly-compose.yaml"
curl -fLO "https://github.com/sparkmoxie/TautWeekly/releases/download/v${TAUTWEEKLY_VERSION}/SHA256SUMS.txt"
grep '  TautWeekly-compose.yaml$' SHA256SUMS.txt | sha256sum -c -
mv TautWeekly-compose.yaml compose.yaml
mkdir -p data
# Set a private .env with TZ, PUID, PGID, UMASK, bind/port, and host policy.
docker compose pull tautweekly
docker compose up -d tautweekly
docker compose ps
```

For reviewed deployments use
`ghcr.io/sparkmoxie/tautweekly:0.23.0`. For unattended automation append the
published manifest digest. Minor, `latest`, and `edge` are mutable and are not
recommended promotion pins. The host owns every pull and recreate; the Manager
has no Docker socket or engine credentials.

## Archive/host-wrapper fallback on another Docker host

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

### Optional custom newsletter text card

The optional Config card immediately after **Cache** places administrator text
before the newsletter release-count/date block. It is disabled by default.

| Option | Default | Accepted value |
|---|---:|---|
| Enabled | `false` | On or off |
| Border color | `#72aef7` | Six-digit hex color |
| Border opacity | `34` | Integer 0-100; 0 hides the border |
| Title | empty | Optional gold uppercase text, 0-120 characters |
| Subheading | empty | Optional large white text, 0-200 characters |
| Body | empty | Required plain text, 1-2000 characters when enabled |

Title and subheading are independently optional, and the layout rebalances
when either is omitted. Line breaks are preserved, and content is escaped for
normal and welcome HTML, the plain-text alternative, and generated previews.
An empty or whitespace-only body blocks browser and Manager API validation,
save, and verification. See the
[configuration reference](../CONFIGURATION.md#optional-custom-text-card).

The following release-archive commands are expert/recovery fallbacks. Run them
from the extracted project directory on the Docker host, not in the container:

```bash
./tautweekly.sh verify
./tautweekly.sh cache-refresh
./tautweekly.sh cache-status
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
`cache-refresh` performs the independent non-sending refresh for every
production-eligible included user's current newsletter window. `cache-status`
prints only share-safe aggregate cache health. It does not print paths, titles,
GUIDs, artwork, credentials, recipients, or manifest contents.

During preview review, confirm the supplied animated movie, TV, and Top Genre
icons; uncapped qualifying personal titles; responsive full-width movie/TV
cards; and matching supporting typography for personal total watch time, Binge
Champion breakdowns, and the Top Genre duration/movie count.

A Hot New Release movie hero pairs with the server-wide Trending footer. A
Trending movie hero never repeats in the footer; it pairs with the anonymous
Top Genre footer and is excluded from the up-to-four **Recent Releases /
Movies** cards. If new TV exists, up to four series remain under **New Releases
/ TV**, while the count above the date and the email preview text both say
`0 NEW MOVIES • X TV TITLE(S)`. If no new TV exists, up to four series strictly
newer than one month appear under **Recent Releases / TV**, and both locations
say `1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when the real hero exists.
Top Genre exposes only aggregate qualified watch time and unique movie count;
missing or unsupported art uses the neutral local movie animation.

Watched marks use only the selected recipient's all-time Tautulli movie history.
Review the desktop poster shield and the title circles with uniform 6px spacing,
vertical centering, and `title="Watched"`. Unwatched movies leave no icon gap and
TV is unchanged. See the [watched-state rule and privacy boundary](../CONFIGURATION.md#recipient-movie-watched-markers).

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

In Manager Config and the terminal fallback, checked/selected rows mean
**excluded**, not selected for delivery. Unchecked active users with an email
address remain eligible even when Tautulli's legacy notification-agent
`do_notify` value is disabled. A manual or scheduled SendAll with no eligible
recipient is recorded as a failed no-delivery attempt with only fixed aggregate
skip reasons; it is never presented as SMTP-accepted success.

**Repeat this Tautulli lookup** updates only the choices displayed by Manager.
At the start of every manual or scheduled SendAll, the shared guarded renderer
makes one bounded Tautulli/Plex user-list refresh and then reads the live
roster. A new eligible user is included unless explicitly excluded; if the
refresh cannot be confirmed, the run stops before SMTP with fixed sanitized
guidance.

Direct configured SMTP remains the standard path. New configurations use
`SendDelaySeconds=30` and `TestSendDelaySeconds=10`. SendAll stops after an
authentication, temporary provider/service, batch-wide, transport, or
ambiguous-DATA failure instead of reconnecting for every remaining recipient;
an address/mailbox-specific RCPT rejection may continue after the configured
delay. Avoid
Test All or a manual production run near the scheduled batch, and stop retries
during a provider account lock.

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

For the generic Compose package, `./tautweekly.sh restart` performs that
single-service recreation and applies current `.env` values while preserving
the image, volumes, `.env`, and `data/`. NAS vendor controls must use their
equivalent recreate/update-container action; a process-only restart cannot
apply changed container environment values.

### Optional private Tailscale access

Manager **Settings > Tailscale** supports every maintained container package
without granting the web process host control. First create a private HTTPS
Tailscale Serve route on the Docker/NAS host to its mapped loopback port (8787
by default), then paste only the resulting exact `https://...ts.net` address,
confirm that Funnel is off, and enable it. Manager saves one hostname, enforces
it as an exact Host value, uses Secure cookies/HSTS and HTTPS same-origin rules
for that host, and keeps its independent password required. It does not accept
an auth key, tunnel token, provider credential, wildcard, port, or URL path.

- **Unraid 7:** use the recommended Tailscale Plugin, sign the server into the
  tailnet, and create a private Serve route to the mapped TautWeekly port. Do
  not put a Tailscale key in the Community Apps template.
- **QNAP:** use the Tailscale App Center package and its documented SSH CLI path
  to create the private Serve route. Container Station continues to own
  TautWeekly; Manager receives no QNAP privilege.
- **Generic Linux/NAS:** prefer the host's supported Tailscale package and a
  private Serve route to `http://127.0.0.1:8787` (or the configured mapped
  port). This is simpler than adding another container.

On first use Tailscale may open a consent page where Funnel is preselected.
Enable **HTTPS certificates only** and turn **Funnel off**. Every remote device
must run Tailscale and be allowed by tailnet policy. For optional mobile use,
install and sign in to the Tailscale app on the phone or tablet, then open the
private address shown by Manager. Every Manager session still has full
administration; no read-only role exists. Local or host access is the recovery
path. Disabling in Manager blocks the saved hostname immediately, but the host
administrator must remove an externally owned Serve route separately.

#### Optional userspace Compose sidecar

Use the shipped sidecar only when the host has no supported Tailscale client.
It uses the official pinned image in userspace mode and a fixed private Serve
config that proxies only to `http://tautweekly:8080`. It has no host network,
Docker socket, `/dev/net/tun`, added Linux capability, Manager credential, or
Funnel entry.

1. In the Tailscale console, create a **one-off** auth key for this node. If the
   tailnet uses device approval or restrictive grants, approve only the intended
   node and users.
2. Create `tailscale/authkey.local` beside the Compose files with mode 0600 and
   place the key there. The path is ignored by Git and excluded from releases.
3. Start the overlay:

   ```bash
   docker compose -f compose.yaml -f compose.tailscale.yaml up -d
   ```

4. Confirm the node is connected and enable **HTTPS certificates only** in the
   provider console. The bundled `${TS_CERT_DOMAIN}` Serve config then creates
   the private address. Never enable Funnel.
5. Empty `tailscale/authkey.local` after the persistent node state is written;
   the one-off key is no longer needed. Keep `tailscale/state/` private and back
   it up or deliberately re-enroll the node after loss.
6. Copy the exact Serve address into Manager Settings and confirm it from a
   separately enrolled device. To stop the sidecar, disable the Manager setting
   first, then run the same two-file Compose command with `stop tailscale` and
   remove only that sidecar deliberately when its retained identity is no longer
   required.

QNAP/Unraid vendor clients are preferred because their host lifecycle and
recovery surfaces are clearer than a sidecar. Never place an auth key in `.env`,
Compose YAML, Community Apps XML, logs, screenshots, or Manager fields.

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

Manager **Settings > Updates** is the primary container update-status source.
It identifies the running application/image, active runtime profile, unified
image repository, recommended semver reference, immutable digest policy,
migration state, release host package, stable channel, latest verified release,
last successful check, sanitized failure, release notes, and whether the saved
host adapter is current, legacy, or mismatched. Authenticated entry renders cached status first
and makes one non-blocking bounded check only when the last success is missing
or at least 24 hours old and backoff permits. Successful results are reused for
five minutes before **Check now** refreshes the same endpoint. The main header
**Refresh** completes its local status reload first, repeats the saved-revision
LAN-only Tautulli choices lookup when configuration is ready, and starts that
check when its cooldown permits. It never generates previews or contacts
Plex/SMTP, and scoped refresh controls remain isolated. Navigation,
Dashboard rendering, and health remain offline-capable. **Current** retains its
green glow. A passive purple header SVG appears only for a validated newer
running application, while the card glows for every non-current state; neither
claims package ownership. The
Manager remains non-root and has no Docker socket or host helper,
so it never offers an install button for Docker/NAS packages.

The guidance is package-specific: Unraid points to Docker/Apps and its current
Community Apps template; QNAP points to Container Station plus the verified
release wrapper over trusted SSH; release-archive Compose/NAS installs show the
copyable `./tautweekly.sh update`; and an otherwise compatible Docker host is
directed to pull and recreate through the same deployment tool that created
the service. Do not add a Docker socket, privileged container, or root web
process to turn those instructions into a GUI update.

For a compatible Compose deployment that did not use the release wrapper, run
from the directory containing the original Compose definition:

```bash
docker compose pull tautweekly
docker compose up -d --no-build --force-recreate tautweekly
```

Preserve the existing `/data` mount and all host environment/port settings.
If the deployment tool uses another service name or is not Compose, use that
tool's equivalent pull-and-recreate operation; do not copy a command into an
unrelated stack.

Release Compose and FreeBSD/Podman packages default to the full release semver.
The `latest` tag advances only for a stable release, the minor tag can move
within its line, and `edge` follows `main`; none is the recommended automation
pin. Use full semver for a reviewed deployment or append the published manifest
digest for an immutable reference. Unraid retains `latest` only because its
host-owned Apps workflow detects and presents digest changes.

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
Manager-triggered preview and delivery operations make one non-blocking lock
attempt and report **Operation busy** immediately; host CLI, scheduler, updater,
and shutdown waits retain their existing bounds.
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
not `edge`, unless deliberately testing unreleased code. After any update,
confirm **Settings > Updates**, then run the Manager verification and controlled
preview/TestEmail sequence again. If
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

### Migrate the v0.22.0 NAS/generic image

The image repository remains `ghcr.io/sparkmoxie/tautweekly`; migrate from
`:0.22.0` by adding `TAUTWEEKLY_RUNTIME_PROFILE=server` and retaining the
appropriate `container-compose`, `nas-docker`, or `qnap-container-station`
package identity. Back up `/data`, record the old digest, and preserve the exact
bind mount or named volume, PUID, PGID, UMASK, timezone, ports, allowed hosts,
secure-cookie setting, and Docker networks. Pull before replacing the healthy
container, recreate with the original host tool, and wait for health. Then sign
in with the existing Manager password and confirm profile/image status, Config,
schedule and history persistence, all six previews, and TestEmail.

If a pull is interrupted, rerun it; the running container and `/data` remain.
If a recreate is interrupted, rerun it against the same mount. If health fails,
restore the recorded `:0.22.0` semver/digest and recreate. An unexpected pairing
screen means the old `/data` is not attached; stop rather than pairing an empty
volume. Never use `docker compose down -v` or delete Unraid appdata. See the
[complete unified image migration contract](../CONTAINER-MIGRATION.md#migrate-the-v0220-nas-or-generic-image)
for named-volume backup, permissions, networking, rollback, interrupted
delivery, and Manager recovery details.

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

## Bundled asset updates

Shipped email asset filenames are release-owned: updates may replace same-name
custom artwork. Custom-only filenames and unrelated private/runtime data are
preserved. For the bundle marker, restart behavior, explicit repair, and Windows
update differences, see [bundled email assets](../EMAIL-ASSETS.md).
