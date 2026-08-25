# macOS Docker Desktop Manager

[Open the macOS Quickstart](https://sparkmoxie.github.io/TautWeekly/mac/)

The Mac archive provides a GUI-first TautWeekly package in Docker Desktop on Intel and Apple-silicon
Macs. It ships the same authenticated Manager core as the other maintained GUI
packages with a macOS-specific capability profile. Manager **Config** is the
source of truth for normal setup, verification, previews, controlled TestEmail
delivery, embedded scheduling, and status. Terminal setup commands are retained
only for expert recovery.

Current source baseline: **1.4.0**.

## Requirements

- Intel (`x86_64`) or Apple silicon (`arm64`) macOS host.
- Current Docker Desktop with Docker Compose available in Terminal.
- A permanent extracted package directory writable by the current Mac user.
- Network access from the container to Tautulli, Plex, and an SMTP STARTTLS
  endpoint. No real service is contacted during package validation.

## Install

1. Download `TautWeekly-mac-docker.tar.gz` or the matching ZIP and
   `SHA256SUMS.txt` from the same stable GitHub release.
2. Verify the archive SHA-256 checksum before extracting it.
3. Extract it to a permanent directory. Do not run it from Downloads and later
   move the directory; the bind-mounted `data/` path belongs to this package.
4. Open Terminal in the extracted directory and run:

```bash
chmod +x INSTALL-MAC.command mac-install.sh tautweekly.sh mac-update.sh check-release.sh package-update.sh app/*.sh app/bin/*.sh
./mac-install.sh
```

The installer verifies Docker Desktop, detects the Mac UID/GID, creates a
mode-0600 `.env`, builds the correct amd64 or arm64 image, starts it, and checks
authenticated Manager liveness. Existing `.env`, `data/`, configuration,
schedules, output, and Manager credentials are preserved. The installer does
not generate or print a default password.

## First-run Manager setup

The Manager is published only at `http://localhost:8787/` by default.

1. Retrieve the one-time pairing token from the package directory:

   ```bash
   ./tautweekly.sh manager-bootstrap
   ```

2. Run `./tautweekly.sh open-manager` or open
   `http://localhost:8787/` in a Mac browser.
3. Enter the token and create a unique administrator password. The token is
   read only by that explicit command, never written to Docker logs or
   diagnostics, and invalidated after pairing.
4. Open **Config**, enter the Tautulli, Plex, SMTP, content, and schedule
   settings, then select **Validate, save, and verify**.
5. Confirm the saved setup results for libraries/users, Tautulli and Plex,
   non-sending SMTP preflight, and local previews.
6. In **Previews**, review all six newsletter states. In **Operations**, send
   the explicit controlled TestEmail check. Enable **Schedule** only after the
   configured timezone, next run, previews, and SMTP result are correct.

Pairing, login, CSRF protection, session expiry, throttling, credential reveal,
and diagnostics use the shared Manager security contracts. Browser reads never
return stored secrets. A service restart invalidates active browser sessions
without disabling the newsletter schedule.

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

## Connect to Mac-hosted Plex and Tautulli

Docker Desktop exposes software running directly on the Mac through
`host.docker.internal`:

```text
http://host.docker.internal:8181   # example Tautulli URL
http://host.docker.internal:32400  # example direct Plex URL
```

For another server, use a name or address reachable from the container. For a
service on the same user-defined Docker network, use its container service
name. Container `127.0.0.1` refers to TautWeekly itself, not the Mac.

Direct Plex access is recommended for full provider ratings, exact-episode
metadata, backgrounds, and selected logos. Manager verification sends the Plex
token in the `X-Plex-Token` header and tests `/identity` plus authenticated
`/library/sections`; it does not put the token in a URL or browser response.

## Metadata readiness before acceptance

After first setup, after changing a Plex metadata agent or **Ratings Source**,
or after a ratings/artwork recovery update when upstream data may be stale:

1. Confirm **Edit > Advanced > Ratings Source** for every included Plex Movie
   library.
2. Run Plex **Manage Library > Refresh All Metadata** for every included movie
   and TV library, and wait for completion.
3. In Tautulli, open each same **Library > Media Info** tab, select
   **Refresh media info**, and wait. The current control is per-library, so
   repeat it for every included section.
4. Return to Manager **Verify**, regenerate PreviewAll, and repeat the
   controlled TestEmail acceptance check.

A full Plex refresh may take substantial time and change artwork. Routine TautWeekly updates do not require a full refresh when current output already
renders correctly.

## Scheduling and graceful lifecycle

The newsletter scheduler is independent from the browser session. Manager
Schedule changes only the typed persistent enable/disable setting; it cannot
alter Docker Desktop, ports, volumes, UID/GID, or host startup settings.
Disabling a future schedule does not cancel a newsletter already running.

Docker Compose grants stop/restart up to 30 minutes. On shutdown, the Manager
stops accepting new work, the supervisor waits for an active newsletter
operation to finish, and only then stops the scheduler. The bounded grace
prevents an ordinary Docker Desktop restart from silently cancelling delivery.

Use the Mac wrapper for lifecycle status:

```bash
./tautweekly.sh status
./tautweekly.sh logs
./tautweekly.sh start
./tautweekly.sh stop
./tautweekly.sh restart
```

`restart` recreates only the `tautweekly` service with the existing image and
volumes, so current `.env` values are applied. It preserves `.env`, `data/`,
configuration, Manager access state, schedules, and generated output.

## Network, reverse proxy, and TLS

The generated `.env` keeps `PREVIEW_BIND=127.0.0.1`; that compatibility name
now controls the authenticated Manager host port. Keep loopback unless trusted
LAN access is intentional. The Manager always requires authentication.

For a deliberate DNS name, add the hostname only (for example,
`weekly.example.com`, with no scheme, port, wildcard, path, or trailing value)
to `MANAGER_ALLOWED_HOSTS`. For HTTPS behind a trusted reverse proxy, preserve
that exact original `Host` header, set `MANAGER_SECURE_COOKIES=true`, terminate
TLS at the proxy, and do not publish the plain HTTP backend. Run
`./tautweekly.sh restart` after either `.env` change so Compose recreates the
service. `Forwarded` and `X-Forwarded-*` never override Host, origin, or TLS
checks. `GET /health/live` is unauthenticated and exposes only liveness;
configuration, paths, versions, credentials, and newsletter state remain
authenticated.

For Cloudflare Tunnel, leave the TautWeekly ingress route without an
`httpHostHeader` override. Rewriting Host to `127.0.0.1`, the container name,
or another backend address causes a deliberate `origin-host-mismatch` because
the browser origin no longer matches the Host received by the Manager.

### Optional private Tailscale access

Install and sign in to the Tailscale macOS client, install its CLI integration,
and create a private background Serve route to the loopback Manager:

```bash
tailscale serve --bg --yes --https=443 http://127.0.0.1:8787
```

If Tailscale presents a provider consent page, enable **HTTPS certificates
only** and turn **Funnel off**. Copy the resulting exact `https://...ts.net`
address into Manager **Settings > Tailscale**, confirm private Serve/Funnel-off,
and enable it. Manager stores only that exact hostname; it receives no
Tailscale credential or Docker control. The Manager password remains required,
and remote sessions have full administration. For optional mobile access,
install and sign in to Tailscale on the phone or tablet, then open the private
address shown by Manager.

For Docker-only hosts that cannot install the native client, the archive also
includes an optional `compose.tailscale.yaml` userspace sidecar. Follow the
[NAS/Docker sidecar procedure](../nas-docker/README.md#optional-userspace-compose-sidecar).
It has no Docker socket, `/dev/net/tun`, added capability, host-network access,
or public Funnel configuration. The native Mac client is the simpler default.

## Newsletter behavior

A Hot New Release movie hero pairs with the server-wide Trending footer. A
movie-empty Trending week uses up to four other recent movies and instead pairs
the hero with the privacy-preserving Top Genre footer. With new TV, up to four
series appear under **New Releases / TV**, and the visible count plus inbox
preview text say `0 NEW MOVIES • X TV TITLE(S)`. Without new TV, up to four
series strictly newer than one month appear under **Recent Releases / TV**, and
both count locations say
`1 TRENDING MOVIE • X RECENT MOVIE RELEASE(S)` when the real hero exists.

Top Genre uses only aggregate qualified movie watch time and unique movie
count; it never includes viewer identity and safely falls back to the neutral
movie animation. Its supporting line and every Binge Champion movie/TV
breakdown use the same supporting typography as personal total watch time.

Watched marks use only the selected recipient's all-time Tautulli movie history.
Review the desktop poster shield and the title circles with uniform 6px spacing,
vertical centering, and `title="Watched"`. Unwatched movies leave no icon gap and
TV is unchanged. See the [watched-state rule and privacy boundary](../CONFIGURATION.md#recipient-movie-watched-markers).

## Persistent data, permissions, and backup

The image is read-only. Writable runtime state is limited to the bind-mounted
package `data/` directory and a bounded in-memory `/tmp`. The entrypoint maps
the non-root container account to the Mac user's `PUID`/`PGID`, creates private
paths, and repairs only legacy ownership within `/data`.

Back up before updates or recovery:

```bash
./tautweekly.sh backup
```

The archive contains configuration, credentials, Manager authentication state,
schedules, output, and the bounded deleted-item cache; keep it private. For a
filesystem-level backup, stop the service and copy both `.env` and `data/`.

## Stable update and rollback

Manager **Settings > Updates** is the primary Mac status source. It separately
reports the container application/image, extracted Mac package, host-adapter
compatibility, stable channel, latest stable release, check history, sanitized
failure, and release notes. Authenticated entry renders cached status first and
makes one non-blocking bounded check only when the last success is missing or
at least 24 hours old and backoff permits. Successful results are reused for
five minutes before **Check now** refreshes the same endpoint. The main header
**Refresh** completes its local status reload first, repeats the saved-revision
LAN-only Tautulli choices lookup when configuration is ready, and starts that
check when its cooldown permits. It never generates previews or contacts
Plex/SMTP, and scoped refresh controls remain isolated. Navigation,
Dashboard rendering, and Manager health remain offline-capable. **Current**
retains its green glow. The passive purple header SVG appears only for a
validated newer running application; the card glows for every non-current
state. The containerized web process
cannot invoke Docker Desktop or change host package files, so the card exposes
the copyable `./tautweekly.sh update` host command but no install button.

`./tautweekly.sh check-update` remains a terminal-only comparison of the installed package
against the latest stable GitHub release and never applies or schedules an
update. macOS does not enable unattended updates.

To upgrade:

1. Run `./tautweekly.sh backup` and keep the previous verified archive.
2. Run `./tautweekly.sh update`. It downloads the matching stable TAR archive
   and `SHA256SUMS.txt`, verifies the published checksum and internal
   `RELEASE-FILES.txt`, and replaces only release-owned files.
3. Open Manager, sign in again if the service restart invalidated the session,
   and verify **Settings > Updates**, Manager/scheduler health, Config status,
   all six previews, and controlled TestEmail result.

The updater takes the same operation lock as the renderer, preserves `.env`,
`data/`, and unrelated administrator files, removes only retired files owned by
the previous release manifest, verifies the running image version and health,
and restores both prior package files and the previous local image automatically
if the candidate fails. Keep the private data backup for independent recovery.
Manager-triggered preview and delivery operations make one non-blocking lock
attempt and report **Operation busy** immediately; host CLI, scheduler, updater,
and shutdown waits retain their existing bounds.

### One-time update from an image-only host wrapper

Packages at or before v0.14.0 can update the image without replacing the Mac
host wrapper. If container startup warns that the host adapter is `legacy`,
download the current stable **Mac Docker** archive and `SHA256SUMS.txt`, verify
the published checksum, and extract the archive over the existing package
directory. Do not delete or replace `.env` or `data/`. Then run
`./tautweekly.sh update`. This one-time overlay installs the verified shared
package updater; later update commands advance the host files and image
together and roll both back on a failed health check.

Manager **Config > Configuration backups** can permanently delete one selected
configuration backup only after **Confirm delete**. This leaves the live
configuration unchanged and cannot be undone.

## Password recovery, reinstall, and uninstall

If the Manager password is lost:

```bash
./tautweekly.sh manager-reset-access
./tautweekly.sh manager-bootstrap
```

Recovery resets only the administrator password and active sessions, waits for
any active newsletter during the controlled restart, and preserves
configuration, schedules, history, output, and delivery state.

For repair/reinstall, verify and extract the same stable archive over the
package, preserve `.env` and `data/`, then run `./tautweekly.sh update`. To
uninstall the application but retain data, run `./tautweekly.sh stop` and keep
the package's `.env` and `data/` in a private backup. Delete the local
`tautweekly-mac:stable` image only after confirming no other project uses it.
Delete `.env`, `data/`, and private backups only when the user explicitly wants
all configuration, credentials, schedules, history, output, and cache removed;
the package never deletes them implicitly.

## Expert/recovery commands

`./tautweekly.sh setup`, `verify`, `preview-all USER_ID`, `send-test-all
USER_ID`, library/user selectors, and schedule commands remain available for
recovery or scripted administration. They are not the normal Mac setup source.
Real-recipient `welcome` and `send-all` commands retain explicit confirmation.
Manager's **Repeat this Tautulli lookup** refreshes only the displayed choices;
every manual or scheduled SendAll performs one bounded Tautulli/Plex user-list
refresh before reading the live roster. A newly eligible user is included
unless explicitly excluded, and an unconfirmed refresh stops before SMTP with
fixed sanitized guidance.

Direct configured SMTP remains the standard path. New configurations use
`SendDelaySeconds=30` and `TestSendDelaySeconds=10`. SendAll stops after an
authentication, temporary provider/service, batch-wide, transport, or
ambiguous-DATA failure instead of reconnecting for every remaining recipient;
an address/mailbox-specific RCPT rejection may continue after the configured
delay. Avoid
Test All or a manual production run near the scheduled batch, and stop retries
during a provider account lock.

## Limitations

- Docker Desktop must be installed, running, and allowed to keep the service
  active; this package does not add a macOS Login Item or background agent.
- It does not ship a native `.app`, menu-bar item, or Apple-notarized installer.
- The Manager is containerized Linux with a truthful `macOS Docker Desktop`
  capability profile; it does not pretend to control native macOS services.
- Automated validation covers shell contracts, amd64/arm64 Manager builds,
  archive contents, security/accessibility behavior, synthetic integrations,
  and Docker-compatible lifecycle rules. A physical Intel/Apple-silicon Mac
  and Docker Desktop remain release acceptance gaps when unavailable in CI.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
