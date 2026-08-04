# Troubleshooting

Start with the platform verifier and correct the first reported failure.

## Tautulli cannot be reached

- Confirm the URL opens from the PlexWeekly runtime, not only from your laptop.
- In Docker, `127.0.0.1` refers to the PlexWeekly container. Use a shared-network
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

## Preview does not open

Windows writes previews under `output/`. Docker editions serve previews on the
configured bind and port. Run `./plexweekly.sh status` and
`./plexweekly.sh logs`, then confirm `PREVIEW_BASE_URL` matches the URL the
browser should use.

## Container permission errors

Confirm `PUID` and `PGID` are non-root and can write the project `data/`
directory. Do not solve the problem by running the application as root. On
Unix-like hosts, restore launcher permissions with:

```bash
chmod +x plexweekly.sh qnap-install.sh mac-install.sh INSTALL-MAC.command app/*.sh app/bin/*.sh
```

Use only the files that exist in your platform distribution.

## Schedule does not send

- Confirm scheduling is enabled.
- Confirm timezone, day, time, grace window, and the same-day attempt guard.
- Windows: run `09-VERIFY-SCHEDULE.bat` as administrator.
- Docker: run `./plexweekly.sh schedule-status` and inspect container logs.

## Mail-client rendering differs from preview

Browser preview is a structural check; the controlled TestEmail is authoritative
for MIME, linked images, and the actual client. Retest after changing branding,
assets, SMTP providers, or email clients.

When requesting help, share the platform, source/release version, failing
command, and sanitized error text. Never attach configuration, state, logs, or
generated mail without removing credentials and personal data.
