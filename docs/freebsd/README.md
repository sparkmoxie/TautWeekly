# FreeBSD installation with Podman

The FreeBSD distribution runs the maintained TautWeekly Linux OCI image through
FreeBSD's Podman Linux-container support. It integrates with the native `rc.d`
service system, exposes the authenticated Manager on host loopback by default,
and keeps configuration, Manager credentials, state, generated output, and
backups in `/var/db/tautweekly`.

[Open the FreeBSD Podman Quickstart](https://sparkmoxie.github.io/TautWeekly/freebsd/)

## Supported target

- FreeBSD 15.1 or newer on amd64.
- Root access through `sudo`, `doas`, or a root shell.
- The configured FreeBSD package repository and internet access to GHCR.
- FreeBSD Linux emulation and Podman; the installer enables both.
- Network access from the Podman container to Plex is recommended for complete
  ratings, backgrounds, and selected logos.

FreeBSD documents the Podman services, automatic container startup, and Linux
container execution in the
[OCI Containers handbook chapter](https://docs.freebsd.org/en/books/handbook/containers/).
This platform is marked **beta** because GitHub-hosted CI performs static,
archive, and OCI checks but does not boot a FreeBSD host. Test preview and SMTP
delivery before enabling the scheduler.

This is not Docker-on-FreeBSD and it does not depend on a native FreeBSD
PowerShell build. The published Linux OCI image supplies the supported
PowerShell runtime and identical application renderer.

## Download and verify

Download `TautWeekly-freebsd-podman.tar.gz` and `SHA256SUMS.txt` from the
[latest release](https://github.com/sparkmoxie/TautWeekly/releases/latest):

```sh
grep 'TautWeekly-freebsd-podman.tar.gz' SHA256SUMS.txt
sha256 -r TautWeekly-freebsd-podman.tar.gz
tar -xzf TautWeekly-freebsd-podman.tar.gz
cd TautWeekly-freebsd-podman
```

Restore launcher permissions when transferring the ZIP through a filesystem
that does not preserve them:

```sh
chmod +x install-freebsd.sh tautweekly package-update.sh rc.d/tautweekly app/*.sh app/bin/*.sh
```

## Install

```sh
sudo ./install-freebsd.sh
sudo tautweekly manager-bootstrap
ssh -L 8787:127.0.0.1:8787 YOUR_FREEBSD_ADMIN@YOUR_FREEBSD_HOST
```

The installer performs explicit host changes: it installs Podman with `pkg` if
needed, enables and starts FreeBSD Linux emulation and the Podman service,
creates an unprivileged numeric data owner, installs the `rc.d` integration,
pulls the public GHCR image, and starts the container. It preserves an existing
settings file and private data directory. Open `http://127.0.0.1:8787/` through
the tunnel, enter the one-time token, create a unique administrator password,
and complete **Config** in the Manager. The token is returned only by the
explicit `manager-bootstrap` command and is never printed in installer,
container, or rc.d logs.

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

Manager Config asks for a direct Plex URL and administrator token. They remain optional
for the core Tautulli activity flow, but are recommended for complete movie RT
critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and selected
logos. The URL must work from the Podman Linux container; its localhost is not
the FreeBSD host or a separate Plex service. **Validate, save, and verify**
checks Plex `/identity` plus authenticated `/library/sections` without printing
the token. A resolved but unusable connection fails verification; an unresolved
pair emits a Tautulli-only fallback warning.
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
4. Return to Manager **Verify**, generate PreviewAll, and use TestEmail only
   after both refresh stages complete.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music/photo libraries for TautWeekly.
Tautulli's [section-specific media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require a full refresh when
current output already renders correctly.

In Manager **Config**, review the active movie/TV library scope and delivery
exclusions. Then use **Verify**, generate all six previews, send only to
TestEmail, and inspect **Schedule**. Enable automatic sends only after those
checks pass. The CLI roster and selection commands remain expert/recovery
fallbacks and never save a default preview user.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. Restart the `tautweekly` service after changing
`TAUTWEEKLY_TIMEZONE`.

## Files and trust boundaries

| Path | Purpose |
|---|---|
| `/var/db/tautweekly` | Private `config.json`, Manager password hash/pairing state, schedule state, logs, previews, custom assets, bounded deleted-item cache, and backups |
| `/usr/local/etc/tautweekly/tautweekly.env` | Root-owned image, timezone, identity, bind, port, and URL settings |
| `/usr/local/etc/rc.d/tautweekly` | Native FreeBSD service lifecycle |
| `/usr/local/sbin/tautweekly` | Administrative command wrapper |
| `ghcr.io/sparkmoxie/tautweekly` | Multi-architecture Linux OCI application image |

The settings file contains no SMTP or API credential. Those secrets remain in
`/var/db/tautweekly/config.json`; Manager access state remains under
`/var/db/tautweekly/manager`. Neither path may be committed or shared. Backups,
logs, and previews are also private, and diagnostics never include bootstrap
tokens or raw credentials.

The cache is `/var/db/tautweekly/cache/deleted-items`. It protects future items
observed while live and cannot reconstruct assets already discarded before
v0.9.0. Image updates preserve it with the rest of the data root. To purge,
stop the rc.d service and remove only that directory. During full uninstall,
retain the data root unless configuration, state, output, cache entries, and
backups are all intentionally being removed.

Port 8787 binds to `127.0.0.1` by default. Use an SSH tunnel for Manager access:

```sh
ssh -L 8787:127.0.0.1:8787 admin@example.com
```

Open `http://127.0.0.1:8787/` locally. There is no default password. Sessions
are HttpOnly/SameSite, state changes require CSRF protection, and repeated
failed logins are throttled. Do not publish plain HTTP to the internet. For a
trusted TLS reverse proxy, retain a narrow host bind, set the exact DNS name in
`TAUTWEEKLY_MANAGER_ALLOWED_HOSTS`, set
`TAUTWEEKLY_MANAGER_SECURE_COOKIES=true`, and restart the service.

### Optional private Tailscale access

FreeBSD Tailscale support is community-maintained. Install and sign in to the
host client using the current FreeBSD/Tailscale guidance, then create a private
HTTPS Serve route to the loopback Manager:

```sh
sudo tailscale serve --bg --yes --https=443 http://127.0.0.1:8787
```

Enable **HTTPS certificates only** and turn **Funnel off** if the provider asks
for consent. Copy the resulting exact `https://...ts.net` address into Manager
**Settings > Tailscale**, confirm private Serve/Funnel-off, and enable it. The
containerized Manager stores only the exact hostname and never receives root,
rc.d, Podman, or Tailscale control. Its independent password remains required;
all remote sessions have full administration. Disable the Manager setting
first, then remove the host Serve route if private access is no longer wanted.
For optional mobile use, install and sign in to Tailscale on the phone or
tablet, then open the private address shown by Manager.

## Operations

Use the Manager GUI for normal configuration, verification, library/user
selection, previews, TestEmail, scheduling, status, and sanitized diagnostics.
These commands are host lifecycle, bootstrap, or expert/recovery fallbacks:

```text
sudo tautweekly manager-bootstrap      retrieve the one-time pairing token
sudo tautweekly manager-reset-access   reset only Manager authentication
sudo tautweekly setup                 expert fallback: replace private configuration
sudo tautweekly verify                validate API, mail, storage, and schedule
sudo tautweekly list-users            inspect Tautulli recipients
sudo tautweekly exclude-users         revise stable user exclusions
sudo tautweekly list-libraries         inspect the global movie/TV scope
sudo tautweekly manage-libraries       replace the global movie/TV scope
sudo tautweekly preview-all USER_ID   render all deterministic browser states
sudo tautweekly send-test-all USER_ID send only to TestEmail
sudo tautweekly send-all              guarded production delivery
sudo tautweekly schedule-status       inspect scheduler state
sudo tautweekly status                inspect the rc.d service
sudo tautweekly logs                  follow container logs
sudo tautweekly backup                stop briefly and archive private data
sudo tautweekly check-update          compare verified host package and image
sudo tautweekly update                verify package, install adapter, update image
```

The wrapper always requires an explicit confirmation for real welcome or
production delivery. Excluded users remain available to preview and TestEmail
modes but are omitted from scheduled and confirmed `SendAll` delivery.

Manager Config (or the `manage-libraries` expert fallback) queries active
movie/TV libraries and saves stable section IDs in `IncludedLibraryIds`. This global scope is applied
before releases, quiet mode, Trending, Binge Champion, and personal statistics
are calculated. The manager backs up private configuration before writing;
empty/absent IDs retain legacy all-library behavior.

The inherited newsletter payload lists up to four most-watched movies and four
most-watched TV shows, omits an empty TV stats card, and shows only duration in
Total Watched. Binge Champion shares watch time plus nonzero unique movie and
TV-show counts.
Only new movies qualify for **HOT NEW RELEASE**; movie-empty weeks promote the
normal Trending result while retaining new TV releases below the hero.

## Update and pinning

Manager **Settings > Updates** is the primary FreeBSD status source. It
distinguishes the running container application/image from the installed
FreeBSD Podman package, reports host-adapter compatibility, stable channel,
latest stable release, check history, sanitized failure, and release notes.
Authenticated entry renders cached status first and makes one non-blocking
bounded check only when the last success is missing or at least 24 hours old
and backoff permits. Successful results are reused for five minutes before
**Check now** refreshes the same endpoint. Navigation, Dashboard rendering,
and Manager health stay offline-capable. **Current** retains its green glow.
The passive purple header SVG appears only for a validated newer running
application; the card glows for every non-current state. The web process cannot
run `sudo`, Podman, or rc.d; the
card provides the copyable host command `sudo tautweekly update` but no install
button.

The FreeBSD package uses its rc.d-aware TautWeekly wrapper as the update
authority. Podman's `io.containers.autoupdate=registry` mechanism requires a
systemd-managed container, so the rc.d service deliberately has no auto-update
label or timer. No update is applied periodically by default.

`check-update` compares installed release metadata with the latest stable
package and asks Podman to pull the configured image for a read-only comparison;
it does not restart or replace the container. Before applying, create a private
backup and record the current image ID:

```sh
sudo tautweekly backup
sudo podman image inspect ghcr.io/sparkmoxie/tautweekly:latest --format '{{.Id}}'
sudo tautweekly check-update
sudo tautweekly update
# sign back in; verify Settings > Updates, then Verify, PreviewAll, and TestEmail
```

The apply command downloads the matching stable TAR archive and checksum file,
verifies both the published SHA-256 and internal `RELEASE-FILES.txt`, installs
the current wrapper/rc.d adapter, and then updates the image. It refuses a busy
TautWeekly operation, verifies the in-container health probe and version label,
and retags/restarts the prior image automatically if the new container fails.
Private data under `/var/db/tautweekly` and the existing root-owned environment
file are never replaced. Normal stop/restart gives
the shared service up to 30 minutes to let an already-running newsletter
delivery finish after Manager HTTP access closes.

### One-time update from v0.14.0 or an older image-only wrapper

If `sudo tautweekly help` does not list `manager-bootstrap`, the installed rc.d
host package is older than the Manager inside the image. Download the current
stable **FreeBSD Podman** TAR archive and `SHA256SUMS.txt`, verify the published
checksum, extract it to a temporary directory, and run:

```sh
sudo ./install-freebsd.sh --upgrade-and-update
```

The current installer replaces release-owned application, wrapper, and rc.d
files, preserves `/var/db/tautweekly` and the existing root-owned environment
file, then verifies the updated image. Future `sudo tautweekly update` commands
advance the verified host package and image together. Do not copy individual
wrapper files from an unreleased branch.

If the update addresses missing ratings/artwork or output remains stale,
complete metadata readiness before the listed verify/TestEmail checks.

Manager **Config > Configuration backups** can permanently delete one selected
configuration backup only after **Confirm delete**. The current configuration
is unchanged and the deleted backup cannot be recovered.

For deterministic production updates, set `TAUTWEEKLY_IMAGE` in
`/usr/local/etc/tautweekly/tautweekly.env` to a version tag rather than
`latest`, then restart the service. The release archive also contains the
Dockerfile and complete application source for local inspection or building:

```sh
sudo podman build --os=linux -t localhost/tautweekly:local .
```

Set `TAUTWEEKLY_IMAGE=localhost/tautweekly:local` and restart only after the
local image build succeeds.

The default is stable `latest`. The `edge` tag follows unreleased `main` and is
not a packaged default. Administrators who intentionally want unattended
updates may schedule `tautweekly update` with a FreeBSD host facility, but that
is an explicit local policy and is not installed by this package.

The package defaults to `/usr/local/bin/podman`. If Podman is installed in a
different administrator-managed location, set `TAUTWEEKLY_PODMAN_BIN` in the
same root-owned environment file before restarting the service.

## Manager access recovery

Run `sudo tautweekly manager-reset-access` only when the administrator password
is lost. It removes Manager credentials, pairing material, and active sessions,
then restarts the rc.d service and preserves `config.json`, Tautulli/Plex/SMTP
secrets, newsletter scheduling and delivery state, output, cache, and backups.
Retrieve the replacement one-time token with
`sudo tautweekly manager-bootstrap`. Never delete `/var/db/tautweekly` merely
to recover Manager access.

## Troubleshooting

- `cannot clone: Operation not supported`: confirm FreeBSD 15.1+, run
  `sudo service linux start`, and verify the host's Podman package is current.
- Image does not start: run `sudo podman run --rm --os=linux alpine uname -s`
  to isolate Linux-container support from TautWeekly.
- Service remains stopped: run `sudo service tautweekly status` and
  `sudo podman logs tautweekly`.
- Manager is unreachable: retain the localhost bind and use the SSH tunnel
  above; confirm `sockstat -4 -l | grep 8787`.
- Pairing is requested after an update or browser reset: run
  `sudo tautweekly manager-bootstrap`; do not search logs for the token.
- Permission error: restore the numeric owner with
  `sudo chown -R 8787:8787 /var/db/tautweekly` and keep directory mode `0700`.

TautWeekly for Plex is an independent community project and is not affiliated
with, endorsed by, or sponsored by Plex, Tautulli, or the FreeBSD Project.
