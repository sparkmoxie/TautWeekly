# FreeBSD installation with Podman

The FreeBSD distribution runs the maintained TautWeekly Linux OCI image through
FreeBSD's Podman Linux-container support. It integrates with the native `rc.d`
service system and keeps configuration, state, generated output, and backups in
`/var/db/tautweekly`.

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
chmod +x install-freebsd.sh tautweekly rc.d/tautweekly app/*.sh app/bin/*.sh
```

## Install

```sh
sudo ./install-freebsd.sh
sudo tautweekly setup
sudo tautweekly verify
```

The installer performs explicit host changes: it installs Podman with `pkg` if
needed, enables and starts FreeBSD Linux emulation and the Podman service,
creates an unprivileged numeric data owner, installs the `rc.d` integration,
pulls the public GHCR image, and starts the container. It preserves an existing
settings file and private data directory.

Setup asks for a direct Plex URL and administrator token. They remain optional
for the core Tautulli activity flow, but are recommended for complete movie RT
critic/audience ratings, exact-episode IMDb/RT ratings, backgrounds, and selected
logos. The URL must work from the Podman Linux container; its localhost is not
the FreeBSD host or a separate Plex service. `sudo tautweekly verify` checks
Plex `/identity` plus authenticated `/library/sections` without printing the
token. A resolved but unusable connection fails verification; an unresolved
pair emits a Tautulli-only fallback warning.
Verification proves reachability and authentication, not that every item has
every provider score. The renderer explicitly requests Plex's optional
`Rating` element so available movie RT pairs and exact-episode IMDb/RT values are not
hidden by a selected IMDb/TMDB fallback. If JSON lacks movie RT or
exact-episode provider entries, the renderer retries the same authenticated local
item as XML and reads only provider-labelled `Rating` elements.
For intended movie RT output, also set every applicable Plex Movie library's
**Edit → Advanced → Ratings Source** to **Rotten Tomatoes**,
save, and refresh affected metadata. This is a library-wide Plex choice, not a
TautWeekly setting; leave IMDb/TMDB selected if that fallback is intentional.

Review the roster and every mail state before enabling automatic sends:

```sh
sudo tautweekly list-users
sudo tautweekly exclude-users
sudo tautweekly list-libraries
sudo tautweekly manage-libraries
sudo tautweekly preview-all USER_ID
sudo tautweekly send-test-all USER_ID
sudo tautweekly schedule-status
sudo tautweekly schedule-enable
```

Replace `USER_ID` with a numeric value printed by `list-users`. The roster is
informational and does not select or save a default user.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. Restart the `tautweekly` service after changing
`TAUTWEEKLY_TIMEZONE`.

## Files and trust boundaries

| Path | Purpose |
|---|---|
| `/var/db/tautweekly` | Private `config.json`, state, logs, previews, custom assets, bounded deleted-item cache, and backups |
| `/usr/local/etc/tautweekly/tautweekly.env` | Root-owned image, timezone, identity, bind, port, and URL settings |
| `/usr/local/etc/rc.d/tautweekly` | Native FreeBSD service lifecycle |
| `/usr/local/sbin/tautweekly` | Administrative command wrapper |
| `ghcr.io/sparkmoxie/tautweekly` | Multi-architecture Linux OCI application image |

The settings file contains no SMTP or API credential. Those secrets remain in
`/var/db/tautweekly/config.json`, which must never be committed or shared.
Backups, logs, and previews are also private.

The cache is `/var/db/tautweekly/cache/deleted-items`. It protects future items
observed while live and cannot reconstruct assets already discarded before
v0.9.0. Image updates preserve it with the rest of the data root. To purge,
stop the rc.d service and remove only that directory. During full uninstall,
retain the data root unless configuration, state, output, cache entries, and
backups are all intentionally being removed.

Port 8787 binds to `127.0.0.1` by default. Use an SSH tunnel for remote preview:

```sh
ssh -L 8787:127.0.0.1:8787 admin@example.com
```

Open `http://127.0.0.1:8787/` locally. Do not publish the unauthenticated
preview server directly to the internet.

## Operations

```text
sudo tautweekly setup                 create or replace private configuration
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
sudo tautweekly check-update          stage/check the configured image only
sudo tautweekly update                pull the configured image and restart
```

The wrapper always requires an explicit confirmation for real welcome or
production delivery. Excluded users remain available to preview and TestEmail
modes but are omitted from scheduled and confirmed `SendAll` delivery.

The setup and `manage-libraries` commands query active movie/TV libraries and
save stable section IDs in `IncludedLibraryIds`. This global scope is applied
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

The FreeBSD package uses its rc.d-aware TautWeekly wrapper as the update
authority. Podman's `io.containers.autoupdate=registry` mechanism requires a
systemd-managed container, so the rc.d service deliberately has no auto-update
label or timer. No update is applied periodically by default.

`check-update` asks Podman to pull the configured image into local storage and
compares it with the running container; it does not restart or replace that
container. Before applying, create a private backup and record the current
image ID:

```sh
sudo tautweekly backup
sudo podman image inspect ghcr.io/sparkmoxie/tautweekly:latest --format '{{.Id}}'
sudo tautweekly check-update
sudo tautweekly update
sudo tautweekly verify
sudo tautweekly send-test-all USER_ID
```

The apply command refuses a busy TautWeekly operation, recreates the rc.d
service, verifies the in-container health probe and version label, and retags
and restarts the prior image automatically if the new container fails. Private
data under `/var/db/tautweekly` is never replaced.

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

## Troubleshooting

- `cannot clone: Operation not supported`: confirm FreeBSD 15.1+, run
  `sudo service linux start`, and verify the host's Podman package is current.
- Image does not start: run `sudo podman run --rm --os=linux alpine uname -s`
  to isolate Linux-container support from TautWeekly.
- Service remains stopped: run `sudo service tautweekly status` and
  `sudo podman logs tautweekly`.
- Preview is unreachable: retain the localhost bind and use the SSH tunnel
  above; confirm `sockstat -4 -l | grep 8787`.
- Permission error: restore the numeric owner with
  `sudo chown -R 8787:8787 /var/db/tautweekly` and keep directory mode `0700`.

TautWeekly for Plex is an independent community project and is not affiliated
with, endorsed by, or sponsored by Plex, Tautulli, or the FreeBSD Project.
