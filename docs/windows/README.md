# Windows installation and Manager guide

[Open the Windows Quickstart](https://sparkmoxie.github.io/TautWeekly/windows/) ·
[Download the latest Setup](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe)

`TautWeekly-Setup.exe` and the local Manager are the supported Windows install,
configuration, verification, preview, update, and scheduling experience. The
numbered BAT files are retained for portable recovery and advanced diagnostics;
they are not the normal setup flow.

Current Windows package baseline: **1.9.0**.

## Requirements

- 64-bit Windows 10 or 11.
- Windows PowerShell 5.1 or newer. It is included with supported Windows
  versions and is used by the packaged newsletter renderer.
- Network access to Tautulli and an SMTP server that supports STARTTLS.
- A Tautulli API key.
- Optional but recommended direct Plex access for complete ratings, artwork,
  backgrounds, and selected logos.
- Administrator approval only when changing the optional Windows Scheduled
  Task. Setup and the Manager otherwise run for the current Windows account.

Plex and Tautulli may run on this computer or on another reachable LAN host.
Use `127.0.0.1` only for a service running on the same Windows computer.

## Install, update, or migrate with Setup

1. Download
   [`TautWeekly-Setup.exe`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe)
   and
   [`SHA256SUMS.txt`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/SHA256SUMS.txt)
   from the same release.
2. Verify the executable's SHA-256 value against `SHA256SUMS.txt`:

   ```powershell
   Get-FileHash .\TautWeekly-Setup.exe -Algorithm SHA256
   ```

3. Run Setup and review the selected folder and action before continuing:

   | Situation | Folder to select | Setup action that must appear |
   |---|---|---|
   | Fresh installation | An empty permanent writable folder | **Install** |
   | Existing Setup installation | Keep the registered folder that Setup preselects | **Update** |
   | Older portable/BAT installation | The exact existing TautWeekly folder containing `config.json`, the numbered BAT files, and a valid release ownership manifest | **Migrate** |

   Do not continue a BAT migration unless the button reads **Migrate**. Setup
   refuses an arbitrary non-empty folder and does not scan drives or guess at
   legacy locations.
4. Setup installs for the current Windows account, adds the Start Menu launcher
   and a Desktop launcher when Windows exposes a usable Desktop, registers
   uninstall information, and opens the loopback-only Manager. The default
   application folder is
   `%LOCALAPPDATA%\Programs\TautWeekly`; a fresh install may use another
   permanent writable location.

The unsigned initial release can trigger Windows SmartScreen. Confirm the
official SHA-256 value before choosing **Run anyway**. The unknown-publisher
warning is a code-signing limitation, not evidence that the hash is wrong.

### What Setup preserves

Update and migration replace only release-owned files. Setup preserves private
`config.json`, state, logs, cache, output/previews, custom assets, Manager
history, and compatible Task Scheduler state. It creates a private timestamped
backup before replacement and automatically performs a rollback of
release-owned files if verification fails. The backup can contain credentials
and must not be shared.

When updating an existing Setup installation, keep its registered folder.
Changing the installed folder requires uninstalling the application first;
normal uninstall preserves private data. Setup never installs a periodic update
task and never follows GitHub `main` or a container `edge` tag.

### Check and install from Settings

Manager **Settings > Updates** is the primary Windows version and update-status
view. It shows the running Manager/application version, installed package
version, stable channel, latest stable release, comparison state, last
successful check, last sanitized failure, and release-notes link. Authenticated
entry renders cached status first and makes one non-blocking bounded request
only when the last success is missing or at least 24 hours old and backoff
permits. Opening or refreshing the Dashboard does not itself contact GitHub;
successful results are reused for five minutes, then **Check now** permits an
explicit refresh. A purple header notification
appears only for a validated newer running application and links to this view;
the status card glows for every non-current state while the green **Current**
chip remains unchanged. Neither cue starts installation.

When a newer verified stable release is available, Windows alone shows
**Install update** behind a separate confirmation. That action starts the
existing fixed `Check-Update.ps1` workflow; it accepts no browser-supplied URL,
path, version, command, or arguments, and Windows still requests administrator
approval before files or Scheduled Task state can change. The updater verifies
the official release URL, published checksum, archive layout, and internal
release manifest, preserves private data, checks post-update health, and rolls
back release-owned files on failure. There is no unattended update task.

## First launch

The Windows Manager binds to `127.0.0.1:8788` and opens directly for the current
Windows account. Windows trusted-local mode does **not** require a pairing token
or a password on first run. The packaged TautWeekly logo also appears in the
Windows notification area for as long as the interactive Manager is running.

- A new installation opens the Dashboard with a blue **First time setup** card.
  Select **Setup** to open **Config**.
- If Setup migrated an existing `config.json`, review the existing values and
  select **Validate, save, and verify**. Stored secrets remain preserved unless
  explicitly replaced or cleared.
- The lock icon in the Manager header reports whether browser access is locked
  and links to the password controls under **Settings**.

Older BAT-era configurations may predate `PlexServerUrl` and `PlexToken`.
The Manager labels that case as a legacy omission instead of implying that
Setup erased the values. For Plex on the same computer, use
`http://127.0.0.1:32400`; the Windows runtime can use the current account's
local Plex token without copying it into `config.json`. If Plex runs elsewhere,
enter the URL reachable from this computer and paste its administrator token.
The next validated save adds the current direct-Plex fields while preserving a
private backup of the original file.

Opening or refreshing the Dashboard does not contact Tautulli, Plex, or SMTP and
does not change configuration.

## Optional private access with Tailscale

Under **Settings > Tailscale**, Windows can publish the loopback Manager through
Tailscale Serve as private HTTPS. TautWeekly never enables Funnel, opens a
router port, or creates a public URL. There is no URL to paste into Config: after
Tailscale verifies the route, Manager displays the exact generated `.ts.net`
address.

Prerequisites are irreducible: install Tailscale on this computer, sign it into
your tailnet, and install/sign in to Tailscale on each remote computer or mobile
device that should connect. Tailnet grants still decide which enrolled users
and devices can reach this computer. The remote address is not usable from an
ordinary Internet browser without a Tailscale client.

Turning the switch on or off, or choosing **Verify with Windows**, requests a
normal Windows administrator confirmation. Manager itself stays unelevated.
The fixed packaged helper accepts only Inspect, Enable, or Disable for Manager's fixed
loopback port, refuses an unrelated Serve configuration, and verifies the exact
HTTPS route after changing it. Opening or refreshing Dashboard never prompts
for administrator access. On a tailnet that has not enabled HTTPS certificates,
Tailscale may also require its own one-time web consent before setup can finish.
That provider page can preselect **Tailscale Funnel**. Enable **HTTPS
certificates only** and turn Funnel off; TautWeekly never needs public Funnel
access.

The Windows Manager password remains optional. With the lock off, every user or
device permitted by the tailnet to reach this computer receives full Manager
administration; there is no read-only remote role. Enabling the independent
Manager password adds a second login without changing Tailscale membership.
Local `http://127.0.0.1:8788` remains the recovery path. Disable blocks the saved
private hostname locally before attempting to remove the owned Serve route.

## Notification area and sign-in startup

The notification-area icon is the persistent Windows control for the local
Manager:

- Hover over the TautWeekly icon to see **TautWeekly Dashboard**. Left-click it
  to bring an existing visible Dashboard browser window to the foreground,
  opening one only when no Dashboard window is available. Opening TautWeekly
  again also reuses this same Manager; it does not create a second server, tray
  process, or visible duplicate Dashboard window.
- Right-click to see one native status row: **Healthy**, **Needs attention**, or
  **Failed**. The row includes a colored native menu icon, while the text keeps
  the state understandable without color. Select the status row to focus the
  existing Dashboard, opening one only when no Dashboard window is available.
- Select **Exit TautWeekly for Plex** to remove the icon and stop the local
  Dashboard server gracefully.

Closing a browser tab does not exit the background Manager. Conversely, Exit
stops only the Manager/control surface. It does not disable or remove the
weekly Windows Scheduled Task, and it does not cancel a newsletter delivery
already running. The task remains able to start future newsletters without the
Manager open.

Under **Settings > Manager startup**, Windows provides two current-user,
non-administrator controls:

1. **Start Manager when I sign in** starts the Manager silently in the
   notification area for the signed-in Windows user.
2. **Open Dashboard after sign-in** becomes available only when the first
   setting is on. It opens the default browser once, after the background
   Manager is ready.

Each toggle saves immediately. The status badge changes only after Windows
confirms the new setting; if the update fails, the toggle returns to its last
saved state and the Manager shows a sanitized error.

Setup refreshes an owned sign-in entry after update or portable migration,
including when the private data path changes. Uninstall removes that owned
entry while preserving private configuration and Manager data. A later fresh
install starts with sign-in startup off unless a recognized older TautWeekly
entry is being repaired. Password-access reset does not change either startup
choice or the newsletter schedule. If Settings reports an entry conflict, the
same-named unrecognized Windows entry is left untouched for safety.

## Configure in the Manager

The **Config** page replaces hand-editing JSON and the legacy setup wizard. It
guides all supported values and keeps secrets write-only after save.

| Config area | What to provide |
|---|---|
| Connections | Tautulli URL and API key; optional direct Plex URL and token |
| Email | Sender display name, sender address, optional reply-to address, and a controlled `TestEmail` recipient |
| SMTP | Host, STARTTLS port (commonly 587), authentication setting, username, and application password when required |
| Newsletter | Lookback window, content limits, branding, and other supported renderer settings |
| Custom text card | Optional border, title, and subheading plus a required body when enabled |
| Schedule | Desired local Windows day and time; saving configuration does not install the task |
| Guided scope | Included movie/TV libraries and users excluded from production delivery |

Secrets are never returned in the normal Config response. Leaving a stored
secret blank preserves it; use the explicit reveal, replace, or clear controls
when needed. Every successful save creates a private timestamped backup before
`config.json` is replaced.

Under **Config > Configuration backups**, Restore validates the chosen backup
and first saves the current configuration. Delete requires **Confirm delete**,
permanently removes only that selected backup, and leaves the live configuration
unchanged.

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

### Validate, save, and verify

Select **Validate, save, and verify** after reviewing the form. One safe,
non-sending operation updates four persistent Config status cards:

1. **Libraries and users** loads active movie/TV libraries plus sanitized user
   IDs, display names, and roles from Tautulli. It does not retain email
   addresses in the Manager discovery cache.
2. **Tautulli and Plex** verifies the saved Tautulli API and the configured
   direct Plex identity and authenticated library access.
3. **SMTP preflight** checks DNS/TCP, the SMTP greeting, EHLO, and
   certificate-validated STARTTLS. It does not authenticate or submit a
   message.
4. **Local previews** prepares the six newsletter states when one unambiguous
   owner or administrator ID and the required metadata are available.

The four cards persist across browser refreshes and Manager restarts for the
current saved configuration. The Dashboard summarizes them in **Config
status**. A later validation replaces the recorded results. Each check also
remains available for an explicit manual retest under **Config**, **Verify**, or
**Previews**.

After discovery, select the libraries included in newsletter calculations and
the users excluded from production delivery, then save. These selections remain
in `config.json`; the guided display is retained until another validation
refreshes the available choices. Library scope filters releases, quiet mode,
Trending, Binge Champion, and personal statistics before calculations run.

User checkboxes are exclusions: checked means excluded. Unchecked active users
with an email address are eligible regardless of Tautulli's legacy
notification-agent `do_notify` value. Manual and scheduled SendAll use the same
policy. A zero-eligible run is a failed no-delivery result with fixed aggregate
skip reasons, never SMTP-accepted success; Manager history retains no recipient
identity or email address.

**Repeat this Tautulli lookup** updates only the choices shown in Config. Every
manual or scheduled SendAll performs one bounded Tautulli/Plex user-list
refresh before reading the live roster, so a new eligible user is included
without another Config save unless explicitly excluded. An unconfirmed refresh
stops before SMTP with fixed sanitized guidance.

Direct configured SMTP remains the standard path. New configurations use
`SendDelaySeconds=30` and `TestSendDelaySeconds=10`. SendAll stops after an
authentication, temporary provider/service, batch-wide, transport, or
ambiguous-DATA failure instead of reconnecting for every remaining recipient;
an address/mailbox-specific RCPT rejection may continue after the configured
delay. Avoid
Test All or a manual production run near the scheduled batch, and stop retries
during a provider account lock.

Validation never authenticates to SMTP, sends email, changes welcome state, or
installs a schedule.

## Review previews and send a controlled test

Open **Previews** after a successful Config validation:

1. Inspect the generated index and six HTML states in scenario order: Manual
   Welcome, New User - No History, New User - With History, Normal Newsletter,
   Established Quiet, and Established Warnings.
2. Confirm artwork, ratings, summaries, personal statistics, conditional cards,
   and responsive layout.
3. When the previews are correct, select a Tautulli owner/administrator ID and
   use the guarded **Send six test messages** action. All six messages go only
   to the configured `TestEmail`.
4. Verify the messages in a real mail client. SMTP acceptance confirms the
   server accepted them; it does not prove inbox placement.

This guarded six-message TestEmail action is the only Manager setup workflow
that authenticates to SMTP or sends mail.

## Send a manual production newsletter

After previews and TestEmail delivery are approved, **Previews** also provides
**Send this week's newsletter now**. This is the primary one-off production
send control; it does not require a Windows Scheduled Task.

The action runs only the packaged `SendAll` mode, applies the saved library and
delivery exclusions, updates the same welcome/history state used by scheduled
delivery, and requires a separate explicit confirmation. It can send real mail
to every currently eligible recipient and cannot be cancelled after it starts.
Once triggered, a dedicated **Current or latest manual send** card retains only
aggregate accepted, skipped, and failed counts. SMTP acceptance does not prove
inbox delivery, and recipient identities are never returned to the browser or
operation history.

## Install the weekly schedule

Saving configuration does not create automation. Open **Schedule** only after
previews and TestEmail delivery are approved.

1. Select **Install** and approve the narrow Windows UAC prompt.
2. Confirm ownership is **Verified**, task state is **Ready**, and the upcoming
   local run is correct.
3. After installation, the same primary button reads **Refresh**. Use it after
   changing the configured day, time, or another task-relevant value.
4. **Enable**, **Disable**, and **Remove** remain separate explicit actions.

The Manager itself remains unelevated. Its typed helper accepts only Install,
Enable, Disable, or Remove, rechecks the exact saved configuration revision, and
will not modify a same-named task unless its executable, arguments, working
directory, and SYSTEM principal belong to this installation. The browser never
supplies an executable, script path, or command string.

Disabling or removing a schedule does not cancel a newsletter process already
running. Task completion, SMTP acceptance, and inbox delivery are separate
status signals.

## Optional Manager password

The default trusted-local behavior is appropriate when only the current Windows
account can use the computer. If that account is shared, open **Settings** and
enable the optional browser password lock.

- Passwords must contain at least 8 characters and are stored only as a salted
  local verifier.
- The header shows a green locked icon when the lock is enabled and a gold
  unlocked icon when it is disabled. Its tooltip describes the current browser
  access state; selecting it opens the password settings.
- **Settings** can change or disable the password later.
- Existing sessions remain active until sign-out or Manager restart.

If the password is forgotten, use the Start Menu **Reset TautWeekly Manager
Access** shortcut or `Reset-TautWeekly-Access.cmd` from the installed folder.
Recovery disables only the Manager lock and restarts local access. It does not
delete configuration, service credentials, startup choices, schedules,
history, or previews.

## Metadata readiness before acceptance

Use this sequence after first setup, after changing a Plex metadata agent or
Ratings Source, or when ratings or artwork remain stale:

1. In every included Plex Movie library, confirm **Edit > Advanced > Ratings
   Source**. Select **Rotten Tomatoes** only when that is the intended source.
2. Run Plex **Manage Library > Refresh All Metadata** for every included movie
   and TV library, then wait for every refresh to finish.
3. In Tautulli, open each same **Library > Media Info** page, select **Refresh media info**,
   and wait. This is a per-library operation, so repeat it for
   every included section.
4. Return to Config and select **Validate, save, and verify** again, then review
   the new previews.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music or photo libraries for TautWeekly.
Tautulli's [per-library media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require this full sequence
when current output already renders correctly.

## Private data, logs, and diagnostics

Installed Manager access settings and sanitized operation history live under
`%LOCALAPPDATA%\TautWeekly\data`. Application data remains in the chosen
TautWeekly folder unless otherwise identified by installer metadata.

- `config.json` - service credentials and supported settings.
- `state.json` and `access-state.json` - newsletter and welcome state.
- `last-run.json` - sanitized latest scheduled application result; it excludes
  recipient identity, titles, viewing history, and credentials.
- `cache\deleted-items\` - bounded exact-GUID presentation metadata and posters
  captured while Plex items are live.
- `output\` - private previews and generated assets.
- `logs\` - local execution logs.
- `%LOCALAPPDATA%\TautWeekly\installer.log` - Setup activity.

Use **Settings > Build and diagnostics** to review sanitized Manager diagnostics
and support codes. None of these private files belongs in source control or a
public support bundle. Remove credentials, recipient information, and viewing
history before sharing an excerpt.

## Network and privacy boundaries

- The Manager listens only on loopback and rejects unrecognized hostnames.
- No cloud control plane, analytics service, or remote Manager account is used.
- Tautulli and direct Plex checks accept private or loopback destinations only,
  disable proxies and redirects, and use short timeouts.
- The Plex token is sent only in the `X-Plex-Token` request header. Tautulli's
  API key uses the query format required by Tautulli.
- SMTP preflight permits a routable unicast provider but stops before
  authentication and message submission.
- Tokens, passwords, recipient identities, viewing history, and generated
  newsletters are not returned in Manager status or diagnostic logs.

## Portable recovery and advanced tools

For a no-install portable or recovery workflow, download and verify
[`TautWeekly-windows.zip`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-windows.zip),
extract it to a permanent writable folder, and run `00-OPEN-MANAGER.bat`.
Portable Manager state lives in `.manager-data\` beside the application.
It is intentionally separate from an installed Manager's private data. Use
`TautWeekly-Setup.exe` and keep the installer-selected existing application
folder when validating an update against installed configuration; Setup reuses
the private data directory recorded by that installation.

The numbered BAT and PowerShell launchers remain available for break/fix
recovery, terminal automation, and detailed troubleshooting. Common fallbacks
include:

- `00-SETUP-FIRST.bat` and `01-VERIFY-SETUP.bat` for terminal configuration and
  verification.
- `05-PREVIEW-ALL-EMAIL-TYPES.bat` and
  `06-SEND-TEST-ALL-EMAIL-TYPES.bat` for the six-state terminal workflow.
- `08-INSTALL-SCHEDULE.bat`, `09-VERIFY-SCHEDULE.bat`, and
  `10-REMOVE-SCHEDULE.bat` for direct schedule maintenance.
- `14-MANAGE-USER-EXCLUSIONS.bat`, `15-MANAGE-LIBRARIES.bat`, and
  `16-LIST-LIBRARIES.bat` for direct scope maintenance.
- `17-CHECK-FOR-UPDATE.bat` for the portable/expert stable update workflow.
- `18-RESET-MANAGER-ACCESS.bat` for portable password-lock recovery.

The Manager's confirmed manual-send card is the normal one-off production
workflow. Choose **Manual Welcome** to send one real welcome newsletter to a
selected Tautulli user, or **All eligible recipients** to run the same full
production delivery as the schedule. The selected Manual Welcome user ID is
never retained in Manager history. Both modes require their own explicit
confirmation, cannot be cancelled after sending starts, and report SMTP
acceptance separately from inbox delivery. `07-SEND-WELCOME-NOW.bat` and
`11-SEND-ALL-NOW.bat` remain expert break/fix fallbacks. Terminal roster output
can contain private names and email addresses; do not publish it.

## Troubleshooting

- If Setup does not show **Migrate** for an old BAT installation, cancel and
  confirm you selected the exact extracted release folder with its ownership
  manifest. Do not choose a parent directory or an arbitrary non-empty folder.
- If a connection check fails, confirm the saved URL is reachable from this
  Windows computer, not only from the Plex/Tautulli host itself.
- If the SMTP preflight passes but TestEmail fails, check authentication,
  application-password, and sender-permission requirements with the mail
  provider.
- If previews are skipped, complete the metadata-readiness sequence and confirm
  Tautulli exposes one unambiguous owner or administrator ID, then validate
  again.
- If a schedule action is declined or interrupted at UAC, refresh the Schedule
  page and review the observed Windows state before retrying.
- If the notification-area icon is hidden by Windows, open the notification
  overflow area and pin TautWeekly. Opening the Start Menu shortcut again
  reuses the running Manager and opens its Dashboard.
- If Manager startup reports **Needs review**, inspect the current user's
  Windows startup apps for an older or modified TautWeekly entry. The Manager
  will not overwrite an entry it cannot identify as its own.

See the full [configuration reference](../CONFIGURATION.md),
[security guidance](../SECURITY.md), and
[troubleshooting reference](../TROUBLESHOOTING.md).
