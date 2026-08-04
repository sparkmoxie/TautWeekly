# Windows portable installation

[Open the rendered interactive Windows walkthrough](https://sparkmoxie.github.io/TautWeekly/windows/)

The Windows distribution runs directly in Windows PowerShell and uses Windows
Task Scheduler for optional automation.

Current source baseline: **1.6.11**.

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1 or newer.
- Network access to Tautulli and an SMTP STARTTLS endpoint.
- A Tautulli API key.
- A permanent writable installation directory.
- Administrator approval only when installing, verifying, or removing the
  scheduled task.

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
   After the Tautulli URL and API key, select any users to exclude from weekly
   delivery. The direct Plex URL and token are optional.
6. Run `01-VERIFY-SETUP.bat` and correct every failure before continuing.

The setup wizard creates `config.json`. That file is deliberately ignored by
git and must remain private.

## Safe acceptance sequence

Run the numbered launchers in this order:

1. `02-LIST-USERS.bat` — review recognized recipients and identifiers.
2. `05-PREVIEW-ALL-EMAIL-TYPES.bat` — generate six local HTML regression
   previews without sending mail.
   Confirm the adaptive one-item cards, movie genres, Binge Champion winner,
   and counted Trending section render as expected.
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

To revise the list without rebuilding the rest of `config.json`, run:

```text
14-MANAGE-USER-EXCLUSIONS.bat
```

Users in that list are skipped by scheduled delivery and confirmed SendAll
runs. Preview and TestEmail commands remain available for safe layout testing;
the separately confirmed one-off welcome command remains an explicit
administrator action. The selector displays names and email addresses, so do
not publish screenshots or terminal output.

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

Back up private configuration and state, extract the new release into a separate
directory, compare the sanitized example configuration, then copy only the live
runtime files you intend to retain. Verify and preview again before replacing
the scheduled task.

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
