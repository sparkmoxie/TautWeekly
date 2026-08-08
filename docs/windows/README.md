# Windows portable installation

[Open the Windows Quickstart](https://sparkmoxie.github.io/TautWeekly/windows/)

The Windows distribution runs directly in Windows PowerShell and uses Windows
Task Scheduler for optional automation.

Current source baseline: **1.7.0**.

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1 or newer.
- Network access to Tautulli and an SMTP STARTTLS endpoint.
- A Tautulli API key.
- A permanent writable installation directory.
- Administrator approval only when installing, verifying, or removing the
  scheduled task, or applying a verified stable update.

Plex and Tautulli may run on another host. Use a resolvable hostname such as
`media.example.test`; `127.0.0.1` is correct only when Tautulli runs on the same
Windows machine.

## Install

1. Download
   [`TautWeekly-windows.zip`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-windows.zip)
   from the latest GitHub release.
2. Verify its SHA-256 value against `SHA256SUMS.txt`.
3. Extract it into a permanent directory. Do not run it from Downloads or a
   temporary extraction view.
4. Run `00-SETUP-FIRST.bat`.
5. Enter your own Tautulli, branding, SMTP, test-recipient, and schedule values.
   After the Tautulli URL and API key, choose the active movie/TV libraries to
   include, then select any users to exclude. The direct Plex URL and token are
   optional.
6. Run `01-VERIFY-SETUP.bat` and correct every failure before continuing.

The setup wizard creates `config.json`. That file is deliberately ignored by
git and must remain private.

## Safe acceptance sequence

Run the numbered launchers in this order:

1. `02-LIST-USERS.bat` — review recognized recipients and identifiers.
2. `05-PREVIEW-ALL-EMAIL-TYPES.bat` — generate six local HTML regression
   previews without sending mail.
   Confirm the supplied animated movie/TV icons, up-to-four most-watched movie
   and TV-show rows, duration-only Total Watched card, anonymous Binge Champion
   duration plus nonzero movie/TV-show counts, gold winner treatment, and Trending hero
   fallback render as expected. The TV stats card is absent when no show was
   watched; TV-only release weeks retain their TV cards below the Trending hero.
3. `06-SEND-TEST-ALL-EMAIL-TYPES.bat` — send those six variants only to the
   configured `TestEmail`.
4. `08-INSTALL-SCHEDULE.bat` — install automation only after the previews and
   real mail-client rendering are approved.
5. `09-VERIFY-SCHEDULE.bat` — confirm the scheduled task identity and action.

`07-SEND-WELCOME-NOW.bat` and `11-SEND-ALL-NOW.bat` send to real users and have
explicit confirmation gates. Read their warnings before use.

## Manage user exclusions

The primary setup lists Tautulli users and accepts comma-separated row numbers
or ranges such as `2,4-6`. Press Enter to keep the displayed selection or type
`none` to clear it. Selections are stored as stable Tautulli IDs in
`ExcludedUserIds`.

The roster is assembled from the bulk `get_user_names` and `get_users`
responses, joined by user ID. Setup does not make a separate `get_user` request
for every row, and name-only rows remain available for exclusion selection.

To revise the list without rebuilding the rest of `config.json`, run:

```text
14-MANAGE-USER-EXCLUSIONS.bat
```

Users in that list are skipped by scheduled delivery and confirmed SendAll
runs. Preview and TestEmail commands remain available for safe layout testing;
the separately confirmed one-off welcome command remains an explicit
administrator action. The selector displays names and email addresses, so do
not publish screenshots or terminal output.

## Manage newsletter libraries

Setup lists active movie and TV libraries from Tautulli and saves the selected
section IDs in `IncludedLibraryIds`. This one global scope filters releases,
quiet detection, Trending, Binge Champion, and personal statistics before the
normal calculations run. Empty or absent values retain the legacy all-library
scope.

Use `16-LIST-LIBRARIES.bat` to inspect the current scope and
`15-MANAGE-LIBRARIES.bat` to replace it without changing SMTP, recipients, or
scheduling. The manager accepts rows, ranges, `all`, or Enter to keep the
current selection, and creates a timestamped `config.backup.*.json` first.

## Runtime files

TautWeekly for Plex creates these files and directories beside the application:

- `config.json` — credentials and settings.
- `state.json` — first-run state.
- `access-state.json` — access and welcome state.
- `logs/` — local execution logs.
- `output/` — previews, posters, and generated content.

None belongs in source control or a public support bundle. Remove secrets and
recipient data before sharing diagnostic excerpts.

## Schedule management

- Install: `08-INSTALL-SCHEDULE.bat`
- Verify: `09-VERIFY-SCHEDULE.bat`
- Remove: `10-REMOVE-SCHEDULE.bat`

The task runs the application from its installation directory. Move the folder
only after removing the task, then reinstall the task from the new location.

## Update

Run `17-CHECK-FOR-UPDATE.bat` to compare this package's repository release
metadata with GitHub's latest stable release. Windows does not create a
periodic update task and never follows GitHub `main` or the container `edge`
tag. If an update exists, the launcher offers three explicit choices:

- `U` — apply the stable update safely.
- `O` — open the stable release page without changing the installation.
- Enter — exit without changing anything.

Choosing `U` downloads the official Windows ZIP and `SHA256SUMS.txt`, verifies
the archive checksum and the package's per-file release manifest, then requests
administrator approval for the replacement step. The updater:

1. Acquires the same installation lock used by newsletter runs and refuses to
   overlap another operation.
2. Refuses a running newsletter task, temporarily disables an enabled task, and
   preserves a task that was already disabled.
3. Creates a timestamped private backup beside the installation folder. The
   backup contains credentials and must not be shared.
4. Replaces only release-owned files. Unowned `config.json`, state files,
   `logs/`, `output/`, and custom-named assets remain in place. An unchanged
   release-owned file removed by the newer package is deleted; a locally
   modified deprecated file is retained.
5. Verifies every installed release-file hash, parses the shipped PowerShell
   files, confirms the repository version, and restores Task Scheduler state.

Any failure after replacement begins triggers automatic file rollback. If
rollback cannot complete, the scheduled task stays disabled and the updater
reports the private backup path. After a successful update, run
`01-VERIFY-SETUP.bat`, `05-PREVIEW-ALL-EMAIL-TYPES.bat`, and
`06-SEND-TEST-ALL-EMAIL-TYPES.bat` before the next production send. The sibling
backup is intentionally retained for manual recovery until you are satisfied.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
