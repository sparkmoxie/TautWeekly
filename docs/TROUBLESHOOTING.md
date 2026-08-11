# Troubleshooting

Start with the platform verifier and correct the first reported failure.

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

## User exclusions cannot be loaded

Primary setup continues when the Tautulli roster is temporarily unavailable;
it preserves exclusions from an existing configuration and prints the
standalone command to retry. First run the platform verifier, then use
`14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on Docker, or
`sudo tautweekly exclude-users` on Linux and FreeBSD. Update to v0.5.2 or
newer if every row reports that its user is unavailable. That release replaces
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
container if either the scheduler or preview process terminates.

Inspect the recorded reason with:

```bash
docker inspect tautweekly --format '{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{printf "%q" .Output}}{{println}}{{end}}'
```

An unavailable preview root or a missing, unreadable, or stale
`service-heartbeat.json` remains a real liveness failure. A missing
`movies.gif` now prints a repair warning without declaring the service dead;
run `./tautweekly.sh repair-assets` and `./tautweekly.sh verify`. Scheduler
progress remains visible through `./tautweekly.sh schedule-status` and
`scheduler-heartbeat.json`, but it no longer controls Docker health.

## Preview does not open

Windows writes previews under `output/`. Docker, Linux, and FreeBSD editions
serve previews on the configured bind and port. Use the platform `status` and
`logs` commands, then confirm the preview base URL matches the URL the browser
should use. Native Linux and FreeBSD default to localhost; use the documented
SSH tunnel for remote access.

For Docker Compose, port 8787 is a read-only preview viewer rather than an
administration Web UI. Open the mapped host name or address, not the `*:8787`
notation shown by some Docker status tools. The server root displays setup
guidance even before a newsletter is generated; `preview-all` then creates
`/preview-all-00-INDEX.html`.

If the browser reports **connection refused**, run:

```bash
./tautweekly.sh status
./tautweekly.sh logs
docker compose port tautweekly 8080
docker compose exec tautweekly tail -n 40 /data/logs/preview-server.log
```

The scheduler reads only `/data/config.json`, mapped from the distribution's
`./data/config.json` or the configured Unraid appdata directory. If logs keep
waiting for that file, run `./tautweekly.sh setup` or run `Setup-First.ps1`
from the Unraid container Console. Do not place configuration under
`/opt/tautweekly`; that is the disposable application layer.

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
- Windows: run `09-VERIFY-SCHEDULE.bat` as administrator.
- Docker: run `./tautweekly.sh schedule-status` and inspect container logs.
- Linux and FreeBSD: run `sudo tautweekly schedule-status`, then inspect the
  systemd journal or Podman logs respectively.

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

If the log also says every direct Plex request failed, verify
`PlexServerUrl` from the TautWeekly runtime. In a separate Docker container,
`localhost` and `127.0.0.1` refer to TautWeekly itself, not the Plex
container or NAS host. Use a shared-network Plex service name or another
trusted LAN URL reachable from inside the container, normally on port 32400,
and keep `PlexToken` private. Re-run the platform verifier, PreviewAll, and a
controlled SendTest after correcting the private configuration.

TautWeekly omits a rating rather than guessing its provider. TV/episode IMDb
scores therefore still require an IMDb-labelled source, and a logo is omitted
when Plex/Tautulli has no selected logo resource. Do not post `config.json`,
diagnostic JSON, generated previews, or full logs; share only sanitized warning
text if further help is required.

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
