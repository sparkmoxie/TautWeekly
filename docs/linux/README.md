# Native Linux installation

The native Linux distribution runs TautWeekly for Plex directly with
PowerShell 7. It does not require Docker. A hardened systemd service keeps the
preview server and guarded scheduler alive, while the `tautweekly` command
provides the same setup, exclusion, preview, test, and delivery workflow as the
other editions.

[Open the Native Linux Quickstart](https://sparkmoxie.github.io/TautWeekly/linux/)

## Supported target

- A current 64-bit Ubuntu, Debian, or RHEL release supported by PowerShell 7.
- PowerShell 7.2 or newer (`pwsh`), with a current LTS release recommended.
- systemd, Python 3, `tar`, and util-linux (`runuser` and `flock`).
- Network access to Tautulli, the configured SMTP STARTTLS endpoint, GitHub
  Releases for updates, and optional Plex metadata endpoints.

Microsoft publishes the current distro and PowerShell support table in its
[PowerShell on Linux overview](https://learn.microsoft.com/powershell/scripting/install/linux-overview).
Install PowerShell from Microsoft's supported repository for your distribution
before running this package. The TautWeekly installer deliberately does not add
third-party package repositories or download a runtime as root.

Linux systems without systemd should use the maintained
[NAS/Docker distribution](../nas-docker/README.md).

## Download and verify

Download `TautWeekly-linux.tar.gz` from the
[latest release](https://github.com/sparkmoxie/TautWeekly/releases/latest) with
`SHA256SUMS.txt`, then verify before extracting:

```bash
sha256sum --check SHA256SUMS.txt --ignore-missing
tar -xzf TautWeekly-linux.tar.gz
cd TautWeekly-linux
```

The ZIP contains the same payload for administrators who transfer packages
from Windows. Preserve the executable bits or restore them with:

```bash
chmod +x install-linux.sh tautweekly app/*.sh app/bin/*.sh
```

## Install

```bash
sudo ./install-linux.sh
sudo tautweekly setup
sudo tautweekly verify
```

The installer validates dependencies, creates the locked `tautweekly` service
account, installs application files, enables the service, and preserves any
existing environment and private data. Setup writes the live configuration only
under `/var/lib/tautweekly`.

Review the user roster and exclusions before testing:

```bash
sudo tautweekly list-users
sudo tautweekly exclude-users
sudo tautweekly list-libraries
sudo tautweekly manage-libraries
sudo tautweekly preview-all USER_ID
sudo tautweekly send-test-all USER_ID
sudo tautweekly schedule-status
```

Replace `USER_ID` with a numeric value printed by `list-users`. The roster is
informational and does not select or save a default user.

Before enabling delivery, confirm `Configured TZ`, `Control zone`, and
`Scheduler TZ` agree and that `Scheduler now` has the expected local time and
UTC offset. Restart `tautweekly.service` after changing the timezone in
`/etc/tautweekly/tautweekly.env`.

Automatic delivery is opt-in. Enable it only after the controlled `TestEmail`
messages match the intended production output:

```bash
sudo tautweekly schedule-enable
```

## Files and trust boundaries

| Path | Purpose | Ownership |
|---|---|---|
| `/opt/tautweekly` | Replaceable application code and bundled default assets | `root:root`, read-only to the service |
| `/var/lib/tautweekly` | Configuration, state, logs, previews, custom assets, and private backups | `tautweekly:tautweekly`, mode `0700` |
| `/etc/tautweekly/tautweekly.env` | Non-secret service paths, timezone, and preview listener | `root:root`, mode `0600` |
| `/etc/systemd/system/tautweekly.service` | Hardened service definition | `root:root` |
| `/usr/local/bin/tautweekly` | Administrative command wrapper | `root:root` |

`config.json` contains the Tautulli API key and SMTP credential and may contain a
Plex token. Backups contain the same secrets. Never attach the data directory,
logs, or generated previews to a public issue.

The preview listener defaults to `127.0.0.1:8787`. For remote administration,
keep that bind and use an SSH tunnel:

```bash
ssh -L 8787:127.0.0.1:8787 admin@example.com
```

Then open `http://127.0.0.1:8787/` locally. If a reverse proxy is required,
protect it with authentication and TLS; do not expose the preview server
directly to the internet.

## Operations

```text
sudo tautweekly setup                 create or replace private configuration
sudo tautweekly verify                validate files, API, SMTP, and schedule
sudo tautweekly list-users            inspect Tautulli recipients
sudo tautweekly exclude-users         revise stable user exclusions
sudo tautweekly list-libraries         inspect the global movie/TV scope
sudo tautweekly manage-libraries       replace the global movie/TV scope
sudo tautweekly preview-all USER_ID   generate all deterministic browser states
sudo tautweekly send-test-all USER_ID send only to TestEmail
sudo tautweekly send-all              guarded production delivery
sudo tautweekly schedule-status       inspect scheduler state and heartbeat
sudo tautweekly logs                  follow the systemd journal
sudo tautweekly backup                create a private data archive
```

The backup command briefly stops an active service for a consistent snapshot
and restores its previous running state afterward.

Preview and TestEmail commands may use an excluded user as sample data.

Primary setup and `manage-libraries` discover active movie/TV libraries through
Tautulli and save stable section IDs in `IncludedLibraryIds`. That scope is
applied before releases, quiet mode, Trending, Binge Champion, and personal
statistics are calculated. The manager backs up the private config before
writing; empty/absent IDs retain legacy all-library behavior.
Exclusions apply to scheduled and confirmed `SendAll` delivery. One-off welcome
mail is a separate, explicit administrator action.

## Upgrade and rollback

Download and verify the newer Linux archive, extract it into a temporary
directory, then run:

```bash
sudo ./install-linux.sh --upgrade
sudo tautweekly verify
sudo tautweekly preview-all USER_ID
sudo tautweekly send-test-all USER_ID
```

An upgrade stores the previous application payload under
`/var/lib/tautweekly/backups/program-<timestamp>.tar.gz`, replaces only
`/opt/tautweekly`, and restarts an already configured service. It does not
replace `config.json`, state, output, logs, custom assets, or the environment
file.

To roll back, stop the service, restore the recorded program archive into
`/opt`, and start the service:

```bash
sudo systemctl stop tautweekly
sudo tar -xzf /var/lib/tautweekly/backups/program-TIMESTAMP.tar.gz -C /opt
sudo chown -R root:root /opt/tautweekly
sudo systemctl start tautweekly
```

## Troubleshooting

- `PowerShell 7.2 or newer is required`: install a supported `pwsh` package and
  rerun the installer.
- `systemd is required`: use the NAS/Docker edition on that host.
- Preview works locally but not remotely: keep the localhost bind and use the
  SSH tunnel above.
- Service exits: run `sudo systemctl status tautweekly` and
  `sudo journalctl -u tautweekly -n 200 --no-pager`.
- Permission error under `/var/lib/tautweekly`: restore ownership with
  `sudo chown -R tautweekly:tautweekly /var/lib/tautweekly` and mode `0700` on
  the root directory. Do not run the application as root.

TautWeekly for Plex is an independent community project and is not affiliated
with, endorsed by, or sponsored by Plex or Tautulli.
