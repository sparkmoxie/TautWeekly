# TautWeekly Manager

This directory contains the shared TautWeekly management WebGUI core. Windows,
NAS/container, macOS Docker Desktop, and native service packages supply explicit runtime capabilities, lifecycle
adapters, persistent paths, and schedule providers; the browser never guesses
those boundaries from the operating system.

Current capabilities:

- loopback-only HTTP serving;
- a Windows-native notification-area icon using the packaged TautWeekly
  artwork, native three-state health menu with Dashboard activation, left-click
  Dashboard opening, and graceful Manager-only exit;
- Windows per-installation single-instance coordination that reuses and opens
  the ready Dashboard on a repeated launch;
- current-user sign-in startup and dependent one-time Dashboard opening with a
  platform-capability API, exact entry ownership, and sanitized diagnostics;
- trusted-local Windows access by default, with an optional persistent password
  lock under Settings;
- password create/change/disable controls plus an OS-local recovery command;
- mandatory one-time pairing and password authentication for the
  network-accessible NAS/container runtime;
- server-side sessions and CSRF protection;
- minimal unauthenticated liveness;
- normalized Windows Task Scheduler status;
- secret-redacted configuration reads;
- schema-driven Windows configuration editing;
- optimistic revision checks, server-side validation, and atomic saves;
- private timestamped backups for existing configurations;
- four revision-scoped setup results that persist across refreshes and Manager
  restarts, remain visible on Config, and roll up into a Dashboard Config
  status card;
- metadata-only backup listing, revision-checked restore with a pre-restore
  safety backup, and authenticated per-backup permanent deletion behind
  same-origin and CSRF checks plus a separate GUI confirmation;
- explicit preserve, replace, or clear semantics for write-only secrets;
- automatic post-save and manually repeatable Tautulli/direct Plex compatibility
  checks restricted to private or loopback destinations, with proxies and
  redirects disabled;
- automatic post-save and manually repeatable Tautulli library/user discovery
  that retains only sanitized library metadata, display choices, stable numeric
  IDs, and explicit owner/administrator roles for the saved configuration;
- a separate non-sending SMTP preflight that verifies DNS/TCP, greeting, EHLO,
  and certificate-validated STARTTLS when enabled, without authentication or
  envelope/message data;
- authenticated, sandboxed preview listing and viewing;
- typed, preview-only Windows generation using the packaged renderer, a
  per-run numeric Tautulli user ID, and a private temporary configuration
  snapshot;
- guarded all-state test delivery through the fixed `SendTestAll` renderer
  mode, restricted to the configured `TestEmail`, with aggregate SMTP
  acceptance evidence only;
- guarded manual production delivery through the fixed `SendWelcome` and
  `SendAll` renderer modes, requiring a selected numeric user for the former,
  distinct recipient-scope messaging, explicit confirmation, and only
  aggregate accepted, skipped, and failed counts;
- single-operation coordination, safe cancellation, restart recovery, and
  bounded sanitized local operation history;
- an opt-in, atomic renderer-result contract that separates preview output,
  failures, and SMTP acceptance without recipient or media details;
- truthful Windows delivery status from the scheduled `last-run.json`, kept
  distinct from Task Scheduler process results and inbox delivery;
- ownership-aware Windows Task Scheduler status plus typed install/refresh,
  enable, disable, and remove operations through a narrowly scoped packaged
  UAC helper;
- a capability-aware Settings update view with application, package, image,
  channel, stable-release, check-history, failure, host-adapter, release-note,
  and platform-owner fields;
- bounded stable-release checks with a sanitized private cache, exponential
  failure backoff, strict GitHub URL/asset metadata validation, one
  authenticated non-blocking refresh when the last success is missing or at
  least 24 hours old, a five-minute successful-result reuse guard, and no
  network dependency in navigation, Dashboard rendering, or health checks;
- a passive purple header notification that appears only for a validated newer
  running application and routes to the consolidated status view without
  taking package-update ownership, plus a card-level attention glow for every
  non-current comparison state;
- an explicitly confirmed Windows-only install action that invokes the fixed
  packaged updater, while native Linux, macOS, FreeBSD, NAS, QNAP, Unraid, and
  compatible Docker modes return guidance without host mutation authority;
- bounded local configuration diagnostics containing only timestamps,
  categories, outcomes, fixed summaries, and support codes; and
- an embedded responsive dashboard with no external runtime assets.

The NAS runtime binds inside the container, separates the read-only package
root from persistent `/data`, requires authentication, accepts IP-literal LAN
Host headers, and accepts DNS names only from the explicit allowlist. It does
not create a tray icon, open a browser, manage sign-in startup, invoke UAC, or
present Windows installer or Task Scheduler controls. Its capability contract
exposes only embedded-scheduler enable/disable actions. Those actions
revision-check `config.json`, make a private atomic backup, update the typed
`ScheduleEnabled` boolean, and verify the postcondition. Container start,
stop, image update, port, volume, UID/GID, TLS, and uninstall remain owned by
the host adapter.

NAS sessions are memory-only, HttpOnly, SameSite=Strict, expire after eight
hours, and use both same-origin checks and a per-session CSRF token for
mutations. TLS reverse-proxy deployments can force Secure cookies and HSTS;
forwarded headers are not trusted. A bounded authentication limiter applies
after five failed attempts in five minutes. Passwords are PBKDF2-HMAC-SHA256
hashed with a random salt, and inputs are limited to 256 UTF-8 bytes before
the KDF. The one-time token exists only in private Manager storage and is read
only by the explicit console command. Recovery removes only Manager
authentication files, after which restart creates a fresh token; newsletter
configuration, credentials, schedules, output, history, and backups remain
untouched.

The macOS runtime is a distinct capability profile over the same container
service core. It requires authentication, publishes to Mac loopback by default,
uses the embedded scheduler, and labels lifecycle and updates as Docker
Desktop/Mac package operations. It suppresses Windows tray, sign-in startup,
Task Scheduler, and installer language. Its host wrapper is the normal source
of pairing-token retrieval and narrow access recovery.

Page load and dashboard refresh never contact Tautulli, Plex, or SMTP. A
successful **Validate, save, and verify** action uses a typed backend impact
plan and runs only affected work: Tautulli changes rerun discovery and
integration checks, Plex changes rerun integration checks, SMTP-card changes
rerun SMTP preflight, and presentation/content/library changes regenerate six
local previews when retained or refreshed discovery reports one unambiguous
owner or administrator ID. Cache, email, schedule, and delivery-delay-only
saves retain applicable results and run no checks or preview work. The SMTP preflight permits a
configured private or public unicast provider but stops before authentication
and sending; SMTP credentials, From-address permission, and real MIME delivery
are validated only by the separately confirmed `TestEmail` operation. Every
automatic check remains manually repeatable. Preview files and the newest
successful preview selection persist on disk, while cached Tautulli choices are
accepted only for the current configuration revision. The four setup outcomes
(choices, Tautulli/Plex, SMTP preflight, and local previews) are retained for
that revision; a save safely rebases only unaffected sanitized evidence to the
new full revision, while restore resets every outcome to not-run. Guarded test delivery is
always manual, sends six messages only to the saved `TestEmail`, and cannot be
cancelled after it starts because some messages may already have been accepted
by SMTP. A separate manual production-send card invokes either the fixed
one-user `SendWelcome` mode or the full `SendAll` mode, requires its own explicit
confirmation, cannot be cancelled, and reports SMTP acceptance separately from
inbox delivery. The selected welcome user ID is passed only to the private
renderer process and is not retained in Manager operation history.

Schedule changes accept only four action enums. The normal Manager remains
unelevated; the packaged helper requests UAC, rechecks the exact configuration
revision, verifies that an existing same-named task belongs to this package,
and fails closed if the post-change Task Scheduler state cannot be observed.
The helper never accepts a browser-supplied executable, path, argument list,
environment block, or command string. Existing BAT workflows remain
available. Automated schedule tests use an injected fictional runner. Live
Windows acceptance has also verified install/refresh, disable, enable,
idempotent refresh, and removal without executing the scheduled newsletter.

Automated acceptance uses sanitized loopback fixtures and never contacts a live
Tautulli, Plex, or SMTP configuration. Separate, explicit live-host acceptance
has verified Tautulli, direct Plex, SMTP preflight, preview generation, and
TestEmail delivery. Manual production delivery uses the same packaged renderer
contract as the scheduled task but is not exercised by automated live
acceptance because it sends to real recipients. Arbitrary command execution
remains unavailable. On Windows, the Manager can start only the existing fixed,
verified `Check-Update.ps1` application path after a fresh successful release
check and explicit confirmation; elevation and file changes remain in the
packaged updater. Other packages expose only their fixed host-side guidance and
cannot invoke Docker, Podman, systemd, rc.d, or package replacement.

The update endpoints use the same session, authorization, allowed-host,
same-origin, CSRF, secure-cookie, HSTS, and rate-limit boundaries as the rest of
the Manager. `GET /api/v1/updates` is local-only and never performs a network
request. `POST /api/v1/updates/check` accepts no release URL and requests only
the fixed stable GitHub API endpoint with redirects rejected, an eight-second
timeout, a bounded response body, strict content type, exact release/tag URL,
and exact platform asset plus checksum URLs. `POST /api/v1/updates/install`
accepts no caller-controlled update arguments. Cached failures contain only
fixed public messages and support codes.

The Windows release build cross-compiles this module as
`tautweekly-manager.exe`, packages it into the portable Windows ZIP, and embeds
that verified ZIP in `TautWeekly-Setup.exe`. Setup is the authoritative Windows
install, update, and portable-migration path. `00-OPEN-MANAGER.bat`,
`START-MANAGER.ps1`, and the local access reset helper remain recovery and
expert interfaces. The installed Manager launcher binds to
`127.0.0.1:8788`, opens the default browser, and keeps optional access-lock and
sanitized operation state under the installer-selected private data directory;
portable copies use `.manager-data`. The legacy BAT/PowerShell workflows remain
available but are not the primary Windows quickstart.

The interactive Windows process owns one native notification-area icon and one
loopback listener. Repeated normal launches wait for the existing Manager and
bring its visible Dashboard browser window to the foreground instead of opening
a duplicate. The native status row performs the same focus-first Dashboard
action. **Exit TautWeekly for Plex** shuts down only the HTTP control surface and
tray process; it neither edits the weekly Task Scheduler definition nor
terminates its newsletter process. A non-cancellable delivery started from the
Manager is allowed to finish in its PowerShell process, and a later Manager
start reconciles the sanitized structured result before accepting another
operation.

Settings exposes `GET` and `PUT /api/v1/startup`. Windows returns the observed
current-user sign-in state without returning command lines or paths. Other
platforms return `supported: false`; their shared UI does not display unusable
Windows controls. Setup refreshes an exactly owned entry after update or
portable migration and removes it on uninstall. Password reset leaves startup
and newsletter schedule settings unchanged.

Operation records do not retain the supplied user ID, configuration values,
service addresses, credentials, command line, or raw renderer output. They
record only sanitized state, timestamps, package version, exit status,
duration, generated preview identifiers, a fixed allowlisted failure category,
and a support code when needed. Categories distinguish package-lock,
configuration, Tautulli, Direct Plex, asset, HTML-render, preview-output, SMTP,
and generic renderer stages; they never contain an exception message, path,
address, media title, or identity. The
local history is bounded to 90 days or 500 completed operations, with the
newest 50 available to the authenticated UI.

Service-package Manager operations make one non-blocking attempt at the shared
newsletter lock and report `operation-busy` immediately when a scheduled,
update, or terminal operation owns it. Host CLI, scheduler, updater, and
shutdown workflows retain their existing package-defined bounded waits.

The latest schedule-operation record is separate and contains only the action
enum, state, timestamps, exit code, sanitized failure category, and support
code. It excludes the configured task name, configuration revision, package
paths, commands, and raw helper output.

Configuration diagnostics are stored privately in
`.manager-data/diagnostic-history.jsonl` and shown only inside the local
Manager under Settings. They retain at most 200 sanitized events for 30
days. Configuration values, URLs, IP addresses, email addresses, user
identities, credentials, media data, raw responses, and command output are not
accepted by the diagnostic schema.

The durable setup summary is stored separately in the private Manager data
directory as `configuration-status.json`. It contains only the configuration
revision hash, fixed step states, timestamps, counts, and sanitized summaries;
it never contains credentials, addresses, email identities, user display
names, or media history.

## Development

Use a supported Go toolchain:

~~~powershell
cd manager
go test ./...
go vet ./...
go build -trimpath -o bin/tautweekly-manager.exe ./cmd/tautweekly-manager
cd ..
python scripts/test-manager-accessibility.py
~~~

Run against the Windows package without creating private data in the source
tree:

~~~powershell
bin/tautweekly-manager.exe serve --listen 127.0.0.1:8788 --tautweekly-root ..\platforms\windows --data-dir C:\path\to\private\manager-data
~~~

Normal Windows launch enters the loopback-only Manager directly. Users may add
or change an optional password under Settings. `18-RESET-MANAGER-ACCESS.bat`
disables only that lock when a password is forgotten. Runtime modes explicitly
started with `--require-auth` retain one-time pairing and must not publish their
pairing URL or private Manager data directory.

The shared top-bar access control shows an open gold lock or closed green lock
and opens the password controls directly. Its tooltip is platform-aware
(`Browser access`, `Container access`, or `Manager access`), so the same control
and password-update route carry into maintained container and native packages.

Windows also exposes an optional Tailscale card below Browser access. Passive
Dashboard loads never invoke Tailscale or request elevation. Explicit Enable,
Disable, and Verify actions use the fixed packaged `TAILSCALE-HELPER.ps1`, which
requests UAC, accepts only Inspect, Enable, or Disable for the Manager loopback target, refuses unrelated Serve
state, never enables Funnel or resets all Serve configuration, and returns a
strict bounded result over a nonce-protected ephemeral loopback callback. The
normal Manager process remains unelevated. The exact verified `.ts.net`
hostname is the only provider value persisted in private Manager state and the
only additional Host header accepted. Requests through that host require HTTPS
origin semantics, Secure session cookies, and HSTS. Origin/Host authority
comparison normalizes DNS case, one trailing dot, and equivalent default ports,
but rejects malformed or different authorities and ignores proxy forwarding
headers. Windows trusted-local and
optional password-lock behavior remain unchanged.

Native Linux uses the same route-ownership contract through a root-owned
systemd accepted socket. Its one-shot helper verifies the Unix peer is exactly
the packaged `tautweekly` service UID and maps only the fixed protocol actions
to the fixed loopback target. Container, macOS Docker, FreeBSD Podman, Unraid,
QNAP, and compatible Docker modes use an external adapter instead: the
authenticated administrator must create private Serve outside Manager, confirm
Funnel is off, and save one exact HTTPS `.ts.net` URL. Manager never receives a
Tailscale key, Docker socket, host command channel, root identity, or wildcard
host. All non-Windows modes retain mandatory Manager authentication.

The implementation specification is
[docs/WEBGUI-IMPLEMENTATION.md](../docs/WEBGUI-IMPLEMENTATION.md).
