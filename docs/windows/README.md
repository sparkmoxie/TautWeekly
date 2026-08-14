# Windows installation

[Open the Windows Quickstart](https://sparkmoxie.github.io/TautWeekly/windows/)

The Windows distribution installs a self-contained local Manager and uses the
packaged PowerShell renderer plus Windows Task Scheduler for optional weekly
automation. The Manager and `TautWeekly-Setup.exe` are the supported primary
setup, verification, update, and scheduling path.

Current source baseline: **1.9.0**.

## Requirements

- 64-bit Windows 10 or 11.
- Windows PowerShell 5.1 or newer.
- Network access to Tautulli and an SMTP STARTTLS endpoint.
- A Tautulli API key.
- Administrator approval only when installing, refreshing, enabling,
  disabling, or removing the optional scheduled task. The normal per-user
  application installation and Manager do not run as Administrator.

Plex and Tautulli may run on another host. Use a resolvable hostname such as
`media.example.test`; `127.0.0.1` is correct only when Tautulli runs on the same
Windows machine.

## Install

1. Download
   [`TautWeekly-Setup.exe`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe)
   from the latest GitHub release and verify its SHA-256 value against
   `SHA256SUMS.txt`.
2. Run the installer and choose the application folder. It installs for the
   current Windows account, adds Desktop and Start Menu shortcuts, and opens
   the loopback-only Manager directly. A password lock is optional under
   **Settings** and is not required for first-run configuration.
   After installation, open **Open TautWeekly Manager**. A new installation
   opens the Dashboard with a blue **First time setup** card that links to
   **Config**; an existing configuration can be validated and saved as-is.
3. Because the initial installer is unsigned, Windows SmartScreen may show an
   unknown-publisher warning. Confirm that the SHA-256 matches the official
   release before choosing **Run anyway**. Code signing remains a release risk,
   not an application requirement.
4. Enter your own Tautulli, branding, SMTP, test-recipient, and schedule values
   in the Manager's guided configuration page. Validate and save once; the
   Manager automatically runs the safe connection checks, loads the active
   movie/TV libraries and available users, and generates local previews when
   the required values are present. Choose the libraries to include and any
   users to exclude, then save those selections. The discovery result is
   retained for later Manager sessions until another validation replaces it.
   Direct Plex remains optional for
   the core Tautulli activity flow, but supplying its URL and administrator
   token is recommended for complete movie RT critic/audience ratings,
   exact-episode IMDb/RT ratings, backgrounds, and selected logos.
5. Review the automatic non-sending Tautulli/Plex, SMTP preflight, discovery,
   and six local preview results. Each section remains available for manual retest.
   If ratings or artwork are missing or stale, complete the metadata-readiness
   checklist below for every included movie/TV library, wait for both applications
   to finish, then select **Validate, save, and verify** again.
6. Correct every failure before continuing, then use the guarded TestEmail
   operation to validate SMTP authentication, sender permission, MIME delivery,
   and real mail-client rendering. `00-SETUP-FIRST.bat` and
   `01-VERIFY-SETUP.bat` remain supported terminal fallbacks.

The default application folder is `%LOCALAPPDATA%\Programs\TautWeekly`; the
folder chooser permits another permanent writable location on a fresh install.
Setup records that choice in the current Windows account. Running a newer
Setup preselects and updates that same folder, which is required to retain the
existing configuration and any installed Task Scheduler ownership. Changing
folders requires removing the installed application first; normal removal
preserves private data. A verified portable Windows release may also be
selected and converted in place. Setup refuses arbitrary non-empty folders and
does not scan drives or guess at legacy locations.

Manager access settings and history live in `%LOCALAPPDATA%\TautWeekly\data`.
Private configuration and renderer state remain unowned application data and
are preserved across upgrades and normal uninstall. The installer log is
`%LOCALAPPDATA%\TautWeekly\installer.log`.

For a no-install portable or recovery workflow, download
[`TautWeekly-windows.zip`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-windows.zip),
verify it, extract it to a permanent writable folder, and run
`00-OPEN-MANAGER.bat`.

The Manager creates `config.json`. That file is deliberately ignored by git
and must remain private.

### Local Manager

The Windows package includes a self-contained Manager that provides the same
configuration through a
loopback-only browser UI, with write-only secret fields, backups and restore,
saved-service connection verification, guided Tautulli library/user choices, a
non-sending SMTP reachability/STARTTLS preflight, sandboxed previews, guarded
six-state test delivery to `TestEmail`, delivery status, and Windows schedule lifecycle
controls. Its four Config verification cards persist across browser refreshes
and Manager restarts for the current saved configuration, and the Dashboard
summarizes them in a separate **Config status** health card. The Manager
executable is built from the repository's Go source as
part of the reproducible Windows release archive. The numbered BAT files remain
supported recovery and expert workflows.

`00-OPEN-MANAGER.bat` starts the Manager hidden, bound only to
`127.0.0.1:8788`, and opens the default browser. Windows trusted-local mode
creates a protected browser session automatically, so first run does not depend
on a pairing token or password. Users who share the Windows account can enable,
change, or disable an optional password lock under **Settings**. If it is
forgotten, the Start Menu **Reset TautWeekly Manager Access** shortcut,
`Reset-TautWeekly-Access.cmd`, or portable `18-RESET-MANAGER-ACCESS.bat`
disables only that lock and restarts the Manager; configuration, service
credentials, schedules, history, and previews remain unchanged. Access policy,
sanitized operation history, and schedule-operation state live in the
installer's external private data directory; portable ZIP installs use
`.manager-data/` beside the application. Stable updates preserve that state and
stop/restart only the exact packaged Manager executable when it is running.

The Manager runs unelevated. Schedule install/refresh, enable, disable, and
remove are the only accepted lifecycle actions. They launch the packaged
helper through Windows UAC, recheck the exact saved configuration revision,
and refuse to modify a same-named task unless its action, arguments, working
directory, and SYSTEM principal match this installation. The browser never
supplies an executable, script path, or command string. Closing or declining
UAC leaves the requested change incomplete.

Nothing contacts Tautulli, Plex, or SMTP merely because the Dashboard opens or
refreshes. Saved-service checks run only during **Validate, save, and verify**
or a separately confirmed manual retest. SMTP preflight stops before
authentication and message submission; the guarded TestEmail operation is the
only Manager workflow that sends mail. Schedule changes require a separate
typed action and UAC approval.

Verification exercises the same resolved direct-Plex connection used by the
newsletter. It sends the token only as a request header and checks Plex
identity plus authenticated library access. An explicitly configured or
auto-discovered connection that cannot be reached or authenticated fails
verification. If Windows cannot resolve a URL/token pair, verification warns
that TautWeekly will use Tautulli's selected/flattened rating fallbacks.
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
4. Run verification, Preview All, and TestEmail only after both refresh stages
   complete.

[Plex documents](https://support.plex.tv/articles/200289306-scanning-vs-refreshing-a-library/)
that a full refresh can take significant time and can update existing metadata
and artwork. Do not refresh unrelated music/photo libraries for TautWeekly.
Tautulli's [section-specific media-info refresh](https://github.com/Tautulli/Tautulli/wiki/Tautulli-API-Reference#get_library_media_info)
updates its table after Plex; it does not replace Plex's refresh or choose a
ratings provider. Routine TautWeekly updates do not require a full refresh when
current output already renders correctly.

SMTP preflight is separate because many mail providers are public rather than
LAN services. It permits routable unicast endpoints, rejects unsafe address
classes, validates the greeting and EHLO exchange, and requires a trusted
certificate when STARTTLS is enabled. It deliberately sends no SMTP username,
password, sender, recipient, subject, newsletter, or message body. Only the
guarded TestEmail operation can validate authentication and sender permission;
SMTP acceptance still does not prove inbox delivery.

## Safe acceptance sequence

Use the Manager in this order:

1. In **Config**, select **Validate, save, and verify**. This loads the active
   movie/TV libraries and available Tautulli users, checks Tautulli and direct
   Plex, runs the non-sending SMTP preflight, and creates six local previews
   when metadata readiness can be confirmed.
2. In **Previews**, inspect all six generated HTML states without sending mail.
   Confirm the supplied animated movie/TV icons, up-to-four most-watched movie
   and TV-show rows, duration-only Total Watched card, anonymous Binge Champion
   duration plus nonzero movie/TV-show counts, gold winner treatment, and Trending hero
   fallback render as expected. The TV stats card is absent when no show was
   watched; TV-only release weeks retain their TV cards below the Trending hero.
3. Use the guarded **Send six test messages** operation. It sends only to the
   configured `TestEmail`; verify all six messages in a real mail client.
4. In **Schedule**, select **Install**, approve the narrow Windows UAC prompt,
   and confirm the Manager reports ownership **Verified**, state **Ready**, and
   the expected upcoming run. Use the same page to refresh, disable, enable, or
   remove the owned schedule.

The numbered BAT launchers remain recovery and expert fallbacks. In particular,
`02-LIST-USERS.bat`, `05-PREVIEW-ALL-EMAIL-TYPES.bat`,
`06-SEND-TEST-ALL-EMAIL-TYPES.bat`, `08-INSTALL-SCHEDULE.bat`, and
`09-VERIFY-SCHEDULE.bat` perform the corresponding terminal workflows.

`07-SEND-WELCOME-NOW.bat` and `11-SEND-ALL-NOW.bat` send to real users and have
explicit confirmation gates. Read their warnings before use.

## Manage user exclusions

After a successful Config validation, the Manager shows the available Tautulli
users in a fixed-height, scrollable selection card. Checked users are excluded
from weekly production delivery. Selections are stored as stable Tautulli IDs
in `ExcludedUserIds`; the Manager discovery cache retains display names and
explicit roles but deliberately does not retain email addresses.

The roster is assembled from the bulk `get_user_names` and `get_users`
responses, joined by user ID. Setup does not make a separate `get_user` request
for every row, and name-only rows remain available for exclusion selection.

The Manager is the primary editor. The terminal fallback is:

```text
14-MANAGE-USER-EXCLUSIONS.bat
```

Users in that list are skipped by scheduled delivery and confirmed SendAll
runs. Preview and TestEmail commands remain available for safe layout testing;
the separately confirmed one-off welcome command remains an explicit
administrator action. The BAT selector can display names and email addresses,
so do not publish its screenshots or terminal output.

## Manage newsletter libraries

After a successful Config validation, the Manager lists active movie and TV
libraries from Tautulli and saves the selected section IDs in
`IncludedLibraryIds`. This one global scope filters releases,
quiet detection, Trending, Binge Champion, and personal statistics before the
normal calculations run. Empty or absent values retain the legacy all-library
scope.

Use the Manager to change the selection and save. As terminal fallbacks,
`16-LIST-LIBRARIES.bat` inspects the current scope and
`15-MANAGE-LIBRARIES.bat` replaces it without changing SMTP, recipients, or
scheduling. The BAT selector accepts rows, ranges, `all`, or Enter to keep the
current selection, and creates a timestamped `config.backup.*.json` first.

## Runtime files

Portable installations create these files beside the application. The
one-click installer preserves the same private files and keeps Manager-only
access settings/history in `%LOCALAPPDATA%\TautWeekly\data`:

- `config.json` — credentials and settings.
- `state.json` — first-run state.
- `access-state.json` — access and welcome state.
- `last-run.json` — sanitized latest scheduled application result; it contains
  counts and timing, never recipient identity, titles, viewing history, or
  credentials.
- `.manager-data/` - the optional local Manager password verifier and access
  policy, sessions, and sanitized operation records. Private state must not be
  shared.
- `cache/deleted-items/` — bounded exact-GUID presentation metadata and posters
  captured while Plex items are live.
- `logs/` — local execution logs.
- `output/` — previews, posters, and generated content.

None belongs in source control or a public support bundle. Remove secrets and
recipient data before sharing diagnostic excerpts.

The cache defaults to 365 days, 1,000 items, and 256 MiB total. It protects
future deletions only; already-deleted assets that Plex/Tautulli discarded
cannot be repaired reliably. Updates preserve this unowned runtime directory.
To purge it, stop newsletter runs and remove only `cache/deleted-items`. For a
full uninstall, remove the schedule first; delete the application folder only
after deciding that configuration, state, cache, output, and backups are no
longer needed.

## Schedule management

The Manager **Schedule** page is the source of truth. It exposes Install or
Refresh, Enable, Disable, and Remove buttons with task-ownership and
postcondition checks, and reports the configured window, current state, and
upcoming run. Windows asks for administrator approval only for the requested
typed lifecycle change. The browser never supplies a command or script path.

The terminal fallbacks are `08-INSTALL-SCHEDULE.bat`,
`09-VERIFY-SCHEDULE.bat`, and `10-REMOVE-SCHEDULE.bat`. Disabling or
removing a schedule does not cancel a newsletter process that is already
running. Task completion, SMTP acceptance, and inbox delivery remain separate
status signals.

The task runs the application from its installation directory. Move the folder
only after removing the task, then reinstall the task from the new location.

## Update or migrate an older portable/BAT installation

Download the newer
[`TautWeekly-Setup.exe`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-Setup.exe)
and verify it against the same release's `SHA256SUMS.txt`.

- Existing Setup installation: run the new EXE. The folder chooser preselects
  the registered application folder and the action reads **Update**. Keep that
  folder and approve the update.
- Older portable/BAT installation: choose the existing extracted TautWeekly
  folder itself. Setup recognizes only a release with a valid ownership
  manifest, labels the action **Migrate**, and converts it in place. It does not
  scan drives or guess at folders.
- Fresh installation: choose an empty permanent folder; the action reads
  **Install**.

Update and migration request administrator approval for the verified
replacement transaction because an owned SYSTEM scheduled task may need to be
paused and restored. The transaction:

1. Acquires the same installation lock used by newsletter runs and refuses to
   overlap another operation.
2. Refuses a running newsletter task, temporarily disables an enabled task, and
   preserves a task that was already disabled.
3. Creates a timestamped private backup beside the installation folder. The
   backup contains credentials and must not be shared.
4. Replaces only release-owned files. Unowned `config.json`, state files,
   `logs/`, `output/`, `cache/`, and custom-named assets remain in place. An unchanged
   release-owned file removed by the newer package is deleted; a locally
   modified deprecated file is retained.
5. Migrates legacy portable `.manager-data/` into
   `%LOCALAPPDATA%\TautWeekly\data` without overwriting a conflicting external
   state file, and removes the duplicate in-folder copy only after success.
6. Verifies every installed release-file hash, parses the shipped PowerShell
   files, confirms the repository version, and restores Task Scheduler state.

Any failure after replacement begins triggers automatic file rollback. If
rollback cannot complete, the scheduled task stays disabled and the updater
reports the private backup path. After success, open the Manager, select
**Validate, save, and verify**, inspect all previews, and complete a controlled
six-message TestEmail run before the next production send. The sibling backup
is intentionally retained for manual recovery until you are satisfied.
If the update addresses missing ratings/artwork or output remains stale,
complete metadata readiness before those checks.

`17-CHECK-FOR-UPDATE.bat` remains the portable/expert fallback. It compares the
installed release with GitHub's latest stable release and can apply the same
guarded updater after explicit confirmation. Windows installs no periodic
updater and never follows GitHub `main` or the container `edge` tag.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
