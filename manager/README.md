# TautWeekly Manager

This directory contains the Windows-first local TautWeekly management WebGUI.

Current capabilities:

- loopback-only HTTP serving;
- trusted-local Windows access by default, with an optional persistent password
  lock under Settings;
- password create/change/disable controls plus an OS-local recovery command;
- mandatory pairing support reserved for future network-accessible runtime modes;
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
- metadata-only backup listing and revision-checked restore with a pre-restore
  safety backup;
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
- single-operation coordination, safe cancellation, restart recovery, and
  bounded sanitized local operation history;
- an opt-in, atomic renderer-result contract that separates preview output,
  failures, and SMTP acceptance without recipient or media details;
- truthful Windows delivery status from the scheduled `last-run.json`, kept
  distinct from Task Scheduler process results and inbox delivery;
- ownership-aware Windows Task Scheduler status plus typed install/refresh,
  enable, disable, and remove operations through a narrowly scoped packaged
  UAC helper;
- bounded local configuration diagnostics containing only timestamps,
  categories, outcomes, fixed summaries, and support codes; and
- an embedded responsive dashboard with no external runtime assets.

Page load and dashboard refresh never contact Tautulli, Plex, or SMTP. A
successful **Validate, save, and verify** action automatically refreshes the
sanitized Tautulli choices, runs the private-LAN Tautulli/Plex check, runs the
non-sending SMTP preflight, and starts six local previews only when discovery
reports one unambiguous owner or administrator ID. The SMTP preflight permits a
configured private or public unicast provider but stops before authentication
and sending; SMTP credentials, From-address permission, and real MIME delivery
are validated only by the separately confirmed `TestEmail` operation. Every
automatic check remains manually repeatable. Preview files and the newest
successful preview selection persist on disk, while cached Tautulli choices are
accepted only for the current configuration revision. The four setup outcomes
(choices, Tautulli/Plex, SMTP preflight, and local previews) are also retained
only for that revision; saving or restoring a different configuration resets
them before the new checks run. Guarded test delivery is
always manual, sends six messages only to the saved `TestEmail`, and cannot be
cancelled after it starts because some messages may already have been accepted
by SMTP. Production and welcome delivery remain unavailable from the Manager.

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
TestEmail delivery. Manager-initiated package updating, immediate production
sends, and arbitrary command execution remain unavailable. Package installation,
verified updates, and old-portable-folder migration are owned by the separate
`TautWeekly-Setup.exe`; the explicitly confirmed stable-update BAT workflow
remains an expert fallback.

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

Operation records do not retain the supplied user ID, configuration values,
service addresses, credentials, command line, or raw renderer output. They
record only sanitized state, timestamps, package version, exit status,
duration, generated preview identifiers, and a support code when needed. The
local history is bounded to 90 days or 500 completed operations, with the
newest 50 available to the authenticated UI.

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

The implementation specification is
[docs/WEBGUI-IMPLEMENTATION.md](../docs/WEBGUI-IMPLEMENTATION.md).
