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

## User exclusions cannot be loaded

Primary setup continues when the Tautulli roster is temporarily unavailable;
it preserves exclusions from an existing configuration and prints the
standalone command to retry. First run the platform verifier, then use
`14-MANAGE-USER-EXCLUSIONS.bat` on Windows,
`./tautweekly.sh exclude-users` on Docker, or
`sudo tautweekly exclude-users` on Linux and FreeBSD. Confirm the Tautulli API key can run
both `get_user_names` and `get_user`, and that the runtime can reach the exact
configured URL. No exclusion changes are saved when the standalone lookup
returns no selectable users.

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

## Schedule does not send

- Confirm scheduling is enabled.
- Confirm timezone, day, time, grace window, and the same-day attempt guard.
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

When requesting help, share the platform, source/release version, failing
command, and sanitized error text. Never attach configuration, state, logs, or
generated mail without removing credentials and personal data.
