# Troubleshooting

On Windows, NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD Podman,
start with the
authenticated Manager's Dashboard and **Verify** page and correct the first
reported failure. Use the terminal verifier as a recovery/expert fallback.

## Container command reports `/data` access denied

Docker and Podman Console/exec sessions start as the image's root user. Use
the packaged `./tautweekly.sh` host wrapper, or use
`/opt/tautweekly/bin/run-script.sh SCRIPT.ps1` and
`/opt/tautweekly/bin/run-mode.sh MODE` inside an Unraid container Console.
Those launchers run commands as the configured PUID/PGID and repair only
legacy root-owned entries within the dedicated `/data` filesystem.

If an older release already created root-owned logs, update the container and
run any supported launcher command once. For example:

```bash
/opt/tautweekly/bin/run-mode.sh ListUsers
```

Do not work around the error with world-writable permissions or by running the
service as root. The launcher does not follow symlinks or cross another mount,
and it does not display or copy private configuration, logs, or output.

## Tautulli cannot be reached

- Confirm the URL opens from the TautWeekly for Plex runtime, not only from your laptop.
- In Docker, `127.0.0.1` refers to the TautWeekly for Plex container. Use a shared-network
  service name, `host.docker.internal` on Docker Desktop, or a resolvable host
  name.
- Confirm Tautulli's published port and API key.

## SMTP authentication or TLS fails

- Use the provider's STARTTLS hostname and port, normally 587.
- Confirm whether authentication is required and whether the username is a full
  email address.
- Use an application password when the provider requires one.
- Preserve password whitespace unless the provider displays grouped characters
  and `SmtpStripPasswordSpaces` is intentionally enabled.
- `verify` proves that the SMTP host is reachable; it does not authenticate or
  submit mail. Use a numeric ID from `list-users` with `send-test` for the
  authoritative delivery check. Listing users does not save a default.

For Proton SMTP submission, use `smtp.protonmail.ch`, port 587, STARTTLS,
authentication enabled, and `SmtpAuthenticationMethod` set to `Auto` or
`Login`. The username and `FromEmail` must be the exact address paired with the
generated SMTP token; the password must be that token, not a Proton account,
mailbox, or Bridge password. See [Proton's SMTP submission instructions](https://proton.me/support/smtp-submission).
If Proton reports `Sender address rejected: not logged in`, update to a build
containing the explicit SMTP authentication transport, then regenerate or
re-enter the token if the error remains.

## SMTP provider temporarily locks or limits the account

- Stop Test All, manual production sends, and repeated checks. Do not run them
  near the scheduled batch.
- Use `SendDelaySeconds=30` for production and `TestSendDelaySeconds=10` for
  controlled Test All delivery. Spacing reduces cadence but cannot override
  provider account, quota, reputation, or abuse controls.
- v0.19.1 and newer stop the batch after authentication failure, a temporary
  4xx response such as `421`, a batch-wide rejection, transport failure, or
  unknown final-DATA acceptance. The Manager shows only fixed sanitized stage,
  numeric response, and recovery guidance.
- Follow the provider notice and allow a quiet period. A short lock may clear
  quickly; if it does not, wait up to 24 hours before using the provider's
  normal account-recovery process.
- Do not share provider response text, addresses, account data, configuration,
  credentials, or raw logs in an issue.

## User exclusions cannot be loaded

Manager Config preserves exclusions from an existing configuration when the
Tautulli roster is temporarily unavailable. Correct the integration failure on
**Verify**, then reopen Config and retry the roster. Recovery/expert fallbacks
are `14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on Docker, and
`sudo tautweekly exclude-users` on Linux or FreeBSD. Update to v0.5.2 or newer
if every row reports that its user is unavailable. That release replaces
the fragile per-user lookup loop with a two-call merge of `get_user_names` and
`get_users`, keyed by stable user ID. Confirm the Tautulli API key can run both
bulk commands and that the runtime can reach the exact configured URL. A row
from `get_user_names` remains selectable if detailed data is unavailable; no
exclusion changes are saved only when neither endpoint yields selectable users.

## Container is unhealthy

Update to v0.5.3 or newer before investigating an unhealthy Docker service.
Earlier releases used scheduler progress as container liveness, so a normal
scheduled `SendAll` lasting several minutes could age out the heartbeat even
while delivery and previews continued working. Current releases use a separate
five-second service-supervisor heartbeat. The supervisor already exits the
container if either the scheduler or Manager process terminates.

Inspect the recorded reason with:

```bash
docker inspect tautweekly --format '{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{printf "%q" .Output}}{{println}}{{end}}'
```

An unavailable `/health/live` endpoint or a missing, unreadable, or stale
`service-heartbeat.json` remains a real liveness failure. Artwork repair is
separate from Manager liveness; run `./tautweekly.sh repair-assets` only when
generated output reports missing packaged assets. Scheduler progress remains
visible through Manager, `./tautweekly.sh schedule-status`, and
`scheduler-heartbeat.json`, but it no longer controls Docker health.

## Manager or preview does not open

### Private Tailscale address does not open

- Confirm the remote computer or mobile device is connected to the same
  tailnet and permitted by its current grants. Disconnecting the remote client
  is expected to make the private address unreachable.
- In Manager **Settings > Tailscale**, distinguish **Connected** (integrated
  route verified) from **Enabled** (an external exact hostname is allowlisted;
  the host-owned route cannot be inspected by Manager).
- On native Linux, run `tautweekly remote-access-status`. If authorization is
  absent, run `sudo tautweekly remote-access-authorize`, then retry Settings.
  Disable in Manager before using `sudo tautweekly remote-access-revoke`.
- On Windows, choose **Verify with Windows** and approve the UAC prompt. A
  conflicting existing Serve configuration is intentionally left unchanged.
- For a first-use provider link, enable HTTPS certificates only and turn
  Funnel off even if the provider page preselects it.
- For macOS, FreeBSD, QNAP, Unraid, or another host-managed package, inspect the
  host/client Serve state separately and confirm it still proxies the mapped
  loopback Manager port. Disable the Manager setting before removing the route.
- The Manager password remains required outside Windows; Windows keeps its
  existing optional lock behavior. There is no read-only remote role.

Windows, NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD serve previews through the
authenticated Manager. NAS/Docker normally maps host port 8787 to container
port 8080; macOS publishes container port 8080 at `http://localhost:8787/` by
default; native Linux uses loopback port 8788; FreeBSD uses loopback port 8787.
Use the platform `status` and `logs` commands, then confirm the mapped, local,
or tunneled URL is the one the browser opens.

The Manager requires pairing on service/container packages and never has a
default password. On macOS run `./tautweekly.sh manager-bootstrap`; on other
service packages run the platform's explicit `manager-bootstrap` command. The token is never in
installer, container, systemd, or rc.d logs. Complete Config to create the
persistent `config.json`, then use **Validate, save, and verify**, PreviewAll,
and TestEmail in the GUI. Terminal setup and preview commands are recovery or
expert fallbacks on Manager-capable packages.

### Preview generation fails or reports Operation busy

Open **Previews** and read the fixed failure category beside the sanitized
support code. `operation-busy` means a scheduled delivery, update, or explicit
terminal operation currently owns the shared package renderer; wait for that
work to finish and retry. Manager-triggered service-package operations do not
wait on this lock, while host CLI, scheduler, updater, and shutdown workflows
retain their bounded waits. Do not delete the lock file: the live operating-
system file handle, not file presence, determines ownership.

`configuration-invalid`, `tautulli-unavailable`, `plex-unavailable`,
`asset-unavailable`, `render-failed`, `output-failed`, and `smtp-failed` identify
only the fixed stage that stopped. Follow the Manager guidance, run **Verify**
when directed, and retry. Existing preview history remains available unless a
new file was successfully replaced. Browser-extension `content-script.js`,
`ObjectMultiplex`, or `MaxListenersExceededWarning` messages and the expected
blocked-script messages from the script-disabled preview iframe do not identify
a package-renderer failure. Do not add `allow-scripts` to the preview sandbox.

Provide the fixed category, support code, package kind, and whether another
scheduled/update/manual operation was active when asking for help. Do not post
configuration, raw logs, generated previews, private addresses, or identities.

Use **Settings > Updates** as the first update diagnostic. **Unknown** means no
successful stable check is available, the local version is not a release
version, or the configured channel is unsupported; use **Check now** and read
the sanitized failure. **Legacy** means the external wrapper/template predates
the running Manager contract. **Mismatched** means the application/image and
host package report different releases, commonly after an image-only update.
**Newer** means the local application is ahead of the latest stable release and
must not be downgraded automatically. A timeout/offline result does not make
Manager health or newsletter delivery unhealthy, and rapid retries are
temporarily backed off.

The card's update owner is authoritative for the next step: Windows can show a
confirmed install button; Linux, Mac, FreeBSD, Compose/NAS, and QNAP show their
host command; Unraid directs to Docker/Apps and template comparison; generic
Docker directs to the original deployment tool. Never solve a legacy or
mismatched state by mounting the Docker socket, running the Manager as root, or
adding a privileged web helper.

If a NAS user updated the image but `./tautweekly.sh help` does not list
`manager-bootstrap`, the external host wrapper is older than the running image.
The container still supports the GUI. Retrieve the token from the trusted host
without searching logs:

```bash
docker compose exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
  /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager
```

For Unraid, run the same command in the container Console without the
`docker compose exec -T tautweekly` prefix. For a release-archive Compose/QNAP
install, download the current stable NAS archive and `SHA256SUMS.txt`, verify
the checksum, and extract it over the same package directory while preserving
`.env` and `data/`. Future `./tautweekly.sh update` runs verify and advance host
files and the image together. For Unraid, edit the app and compare/apply the
current Community Apps template while keeping the existing appdata path and
identity settings; a `legacy` host-adapter startup warning means this template
refresh is still required.

The same one-time host-package bridge applies to older Mac Docker packages that
updated only the image: verify and extract the current stable Mac archive over
the same package directory while preserving `.env` and `data/`, then run
`./tautweekly.sh update`. On FreeBSD, verify and extract the current stable
FreeBSD Podman archive to a temporary directory and run
`sudo ./install-freebsd.sh --upgrade-and-update`; this preserves
`/var/db/tautweekly` and its root-owned environment file. Native Linux releases
were already package-based: verify the current Linux archive and run
`sudo ./install-linux.sh --upgrade`.

If the browser reports **connection refused**, run:

```bash
./tautweekly.sh status
./tautweekly.sh logs
docker compose port tautweekly 8080
docker compose exec tautweekly tail -n 40 /data/logs/manager.log
```

The container scheduler reads only `/data/config.json`, mapped from the
distribution's `./data/config.json`, configured Unraid appdata directory, or
FreeBSD `/var/db/tautweekly`. If logs keep waiting for that file, sign in and
complete Manager Config. Do not place configuration under `/opt/tautweekly`;
that is the disposable application layer.

For LAN or reverse-proxy access, verify the exact DNS name is listed in the
platform's Manager allowed-host setting. Terminate TLS at a trusted reverse
proxy, enable secure cookies, preserve the original Host header, and do not
publish the plain HTTP backend. IP-literal access needs no DNS allowlist entry.
If a Cloudflare Tunnel route uses an `httpHostHeader` override, remove that
override for the TautWeekly route so cloudflared forwards the browser's public
Host unchanged. Do not add the rewritten loopback or container address to the
DNS allowlist.
An Origin rejection now reports a sanitized code: `invalid-origin` for a
malformed value, `origin-host-mismatch` or `origin-scheme-mismatch` for a real
same-origin difference, and `remote-http` when a saved Tailscale hostname was
used over HTTP. Forwarded headers cannot override these checks. If default
`http://localhost:8787` still fails, provide only the browser address scheme,
sanitized Host shape (localhost, private DNS, or `.ts.net`), and whether a
trusted TLS proxy is in use; do not post the private hostname or credentials.

## Container permission errors

Confirm `PUID` and `PGID` are non-root and can write the project `data/`
directory. Do not solve the problem by running the application as root. On
Unix-like hosts, restore launcher permissions with:

```bash
chmod +x tautweekly.sh qnap-install.sh mac-install.sh INSTALL-MAC.command app/*.sh app/bin/*.sh
```

Use only the files that exist in your platform distribution.

## Schedule does not send or sends at the wrong local time

- Confirm scheduling is enabled.
- Confirm timezone, day, time, grace window, and the same-day attempt guard.
- On non-Windows packages, `Configured TZ`, `Control zone`, and `Scheduler TZ`
  must agree. `Scheduler now` must show the expected local wall time and UTC
  offset. A plausible `Configured TZ` line alone does not prove that the
  long-running scheduler is using it.
- If `Control zone` is invalid, correct the IANA zone before re-enabling the
  schedule. The scheduler deliberately refuses to fall back to UTC.
- If the control and scheduler zones differ after an environment change,
  restart the native Linux service or recreate/restart the Docker or Podman
  container, then run status again.
- Windows: open Manager **Schedule** and review ownership, state, and the
  upcoming run. Choose **Refresh** after changing the install path or schedule
  settings. Use `09-VERIFY-SCHEDULE.bat` as the terminal recovery fallback.
- Docker: run `./tautweekly.sh schedule-status` and inspect container logs.
- Linux and FreeBSD: run `sudo tautweekly schedule-status`, then inspect the
  systemd journal or Podman logs respectively.

## Custom title GIF is missing or does not clear

Open Manager **Config > Custom text card** and inspect **Optional title**. The
empty add-reaction glyph means no GIF is selected. Select Celebrate,
Construction, Rocket, Tickets, Warning, or Alert; selecting the active choice
again clears it. With the in-field control focused, Delete or Backspace also
clears it. Save and regenerate previews after changing the selection.

The GIF renders only when the custom card is enabled, its required body is
present, and its optional title is non-empty. A missing packaged asset or an
unsafe legacy value such as a path, URL, or filename falls back to no GIF. Use
the package's verified update/repair path if an approved asset is missing; do
not add remote image URLs or rename files. Delivered email uses an inline CID,
so a mail client that blocks animation may show only the first frame even when
the MIME attachment and preview are correct.

## Native Linux service does not start

Run `sudo systemctl status tautweekly` and
`sudo journalctl -u tautweekly -n 200 --no-pager`. Confirm PowerShell 7.2 or
newer, Python 3, and util-linux are installed. Application code must remain
root-owned under `/opt/tautweekly`; private data must be writable only by the
`tautweekly` service account under `/var/lib/tautweekly`.

## FreeBSD Podman container does not start

Confirm FreeBSD 15.1+ amd64, then run `sudo service linux status`,
`sudo service podman status`, and
`sudo podman run --rm --os=linux alpine uname -s`. If that Linux-container
probe fails, correct the FreeBSD/Podman host before troubleshooting TautWeekly.
Use `sudo podman logs tautweekly` for application startup errors.

## Mail-client rendering differs from preview

Browser preview is a structural check; the controlled TestEmail is authoritative
for MIME, linked images, and the actual client. Retest after changing branding,
assets, SMTP providers, or email clients.

## Posters render but ratings, backgrounds, or logos do not

These resources do not all use the same path. Posters and hero art can load
through Tautulli's `pms_image_proxy` even when TautWeekly cannot connect to
Plex Media Server directly. Provider-labelled ratings and selected clear logos
may instead require direct Plex metadata or a compatible Tautulli item export.

Update to v0.9.1 or newer if the log says that a rich export failed with HTTP
400. Earlier builds incorrectly requested Tautulli's library/user-only
`individual_files` option for a single `rating_key` export, then expected a
ZIP where Tautulli correctly returns a rating-only JSON file. v0.9.1 follows
the item-export contract and requests metadata level 1 with media information
disabled.

Update to v0.9.2 or newer if the log says TautWeekly could not enumerate
exporter fields or v0.9.1 still produces no movie ratings. Some Tautulli
implementations require a non-null `sub_media_type` despite documenting it as
optional. v0.9.2 sends that compatibility value and explicitly requests only
the four provider-labelled rating fields. It applies the item-export fallback
to movie RT and show IMDb, and validates controlled SendTest delivery
separately from browser preview.

Update to v0.9.5 or newer if movies show IMDb even though another supported
Plex/Tautulli path contains Rotten Tomatoes values. v0.9.4 treated any
recognized selected provider as complete, so a flattened IMDb movie score
could prevent the later rating-only Tautulli export from supplying RT. v0.9.5
exhausts the supported RT sources first and uses labelled IMDb only when no RT
critic or audience value exists.

For TV release rows, v0.10.2 ignores selected TMDB/TVDB as a display substitute
and continues to the exact episode's provider entries. Exact-episode IMDb has
priority. If IMDb is unavailable, the row uses that same episode's Rotten
Tomatoes critic value, then its audience value. It remains unrated when none of
those exact-episode values exist rather than showing a series-level, movie, or
unrelated provider score.

If ratings work on Windows but not in Docker, that can mean Windows reached
Plex directly while the container fell through to Tautulli; it does not imply
that the packages maintain different rating renderers. Comparative logs can
also show Windows receiving RT directly from Tautulli while Docker receives
only a flattened selected IMDb/TMDB value. Versions through v0.9.7 did not
explicitly request Plex's optional `Rating` element in that direct fallback;
v0.9.8 requests it and excludes the case-colliding scalar JSON `rating` field
that can mask the provider array in PowerShell. Update first, then rerun
PreviewAll or SendTest.

Plex documents response include/exclude customization as best-effort rather
than guaranteed. v0.10.1 therefore retries the same authenticated local item
as XML when JSON lacks the media-specific provider entries: movie RT
critic/audience or exact-episode IMDb/RT. This
does not contact a third-party ratings service or change the configured Plex
Ratings Source; it recovers only provider-labelled values already returned by
the user's Plex server.

If the log also says every direct Plex request failed, verify
`PlexServerUrl` from the TautWeekly runtime. In a separate Docker container,
`localhost` and `127.0.0.1` refer to TautWeekly itself, not the Plex
container or NAS host. Use a shared-network Plex service name or another
trusted LAN URL reachable from inside the container, normally on port 32400,
and keep `PlexToken` private. The platform verifier now exercises the same
resolved direct-Plex path used by newsletter generation: it requests
`/identity` and authenticated `/library/sections`, sends the token only in an
HTTP header, and never prints it. An unreachable or unauthorized resolved
connection fails verification instead of surfacing for the first time during
Preview or SendTest. If no URL/token pair can be resolved, verification warns
that only Tautulli's selected/flattened rating and other fallbacks are
available. Re-run the verifier, PreviewAll, and a controlled SendTest after
correcting the private configuration or container networking.

A passing verifier proves authenticated reachability, not that a particular
Plex item publishes each provider score or that Plex/Tautulli metadata is
current. After first install—or when a metadata-recovery update still shows
stale results—prepare every included movie/TV library before acceptance:

1. In Plex Web, confirm the intended **Edit → Advanced → Ratings Source** for
   each included Plex Movie library.
2. Run **Manage Library → Refresh All Metadata** for each included movie/TV
   library and wait for every refresh to finish. A full refresh can be slow and
   can update metadata or artwork; do not refresh unrelated libraries.
3. In Tautulli, open each same **Library → Media Info** tab and choose
   **Refresh media info**. The current control is per library, so repeat it for
   every included section and wait for completion.
4. Re-run the verifier, PreviewAll, and a controlled TestEmail. On v0.9.8 or
   newer, inspect only the sanitized `Design ratings:` lines.

Tautulli's media-info-table refresh does not choose a ratings provider and does
not replace Plex's refresh. If IMDb/TMDB is selected deliberately in Plex,
labelled IMDb is the expected movie fallback. Do not share the configuration,
token, generated preview, recipient information, or full log.

Routine TautWeekly updates do not require this full sequence when current
output already renders correctly.

A passing Tautulli check does not prove direct Plex works. Tautulli and
TautWeekly can run in different containers, networks, DNS contexts, and trust
stores. Likewise, a poster loaded through Tautulli's image proxy does not prove
TautWeekly can query Plex's full alternate `Rating[]`, exact episodes,
backgrounds, or selected logos directly.

TautWeekly omits a rating rather than guessing its provider. A dedicated IMDb
or Rotten Tomatoes badge still requires that provider label. TMDB/TVDB values
are not substituted for movie RT or exact-episode IMDb/RT. Unknown labels and
unlabeled numbers remain hidden, and a logo is omitted when Plex/Tautulli has
no selected logo resource.
Do not post `config.json`, diagnostic JSON, generated previews, or full logs;
share only sanitized warning text if further help is required.

`Optional Plex hosted metadata recovery found no exact match ...` is a
best-effort informational fallback for an exact retained metadata GUID. It may
be attempted for a missing summary, year, genre, or rating and is not proof
that the authenticated local rating lookup failed. Use the final sanitized
`Design ratings:` line to determine which provider values reached rendering.

## Deleted item still has no poster or metadata

v0.8.3's Plex hosted-provider recovery is best-effort. Tautulli history may
retain GUID/rating keys, titles, years, indexes, and viewing fields, but those
rows do not preserve durable image bytes. If Plex/Tautulli discarded the asset
before v0.9.0 observed it live, TautWeekly cannot recover it reliably and will
not guess by title. This is expected for already-deleted items and is not fixed
by changing the cache settings.

For future items, look for an exact-GUID cache-hit message. A miss means the
item was never captured live, has no supported stable GUID, expired, or was
evicted by a configured item/byte limit. A SHA-256 warning means damaged poster
bytes were removed. A manifest warning reports backup recovery or a clean
empty-cache reset; rendering continues without cached data.

Confirm that the runtime account can write `cache/deleted-items` under the
platform's private data root and that the cache is enabled. Do not post the
manifest or artwork publicly. If a clean rebuild is appropriate, stop
TautWeekly, move or remove only that directory, restart, and run PreviewAll
while current library items are still available so new entries can be created.

When requesting help, share the platform, source/release version, failing
command, and sanitized error text. Never attach configuration, state, logs, or
generated mail without removing credentials and personal data.
