# Security and hardening

## Secrets at rest

`config.json` stores a Tautulli API key and SMTP password in plain text, and may
store a Plex token. Limit filesystem access to the account that runs
TautWeekly for Plex. Docker installations use `UMASK=077` and a non-root UID/GID;
Windows installations should use a private directory with appropriate NTFS
permissions. Native Linux uses a dedicated service account and mode-0700
`/var/lib/tautweekly`; FreeBSD uses mode-0700 `/var/db/tautweekly` mounted into
the container with a non-root runtime identity.

Backups contain the same secrets. Encrypt them or place them in protected
storage, and define a retention period.

## Network boundaries

- Keep preview port 8787 off the public internet.
- Prefer localhost binding when previews are consumed on the same host.
- If LAN binding is required, restrict inbound access with the host firewall.
- Use HTTPS for remote Tautulli/Plex endpoints when your environment provides a
  trusted TLS reverse proxy.
- Use SMTP STARTTLS and provider-specific application credentials.

## Delivery safeguards

- Keep `TestEmail` under operator control.
- Review all six preview states and test messages after setup or upgrades.
- Review exclusions and the user roster before a bulk send.
- Treat exclusion-selector output as private: it contains Tautulli names, IDs,
  and recipient email addresses.
- Keep the built-in recipient delay unless your SMTP provider explicitly allows
  a different rate.
- Do not bypass the confirmation switches or wrapper prompts.

## Recipient privacy

Scheduled weekly messages share only the Binge Champion's anonymous aggregate:
total watch time plus nonzero unique movie and TV-show counts. The champion's
friendly name, username, user ID, and watched titles are not disclosed. Only
the winning recipient sees the gold **YOU WON** treatment. Detailed personal
recap rows remain private to each recipient, and one-off welcome messages do not
contain the award.

## Credential rotation

If a credential is exposed, revoke it first, then issue a replacement, update
the live configuration, and verify the affected integration. Deleting a commit
or issue does not make a published credential safe again.

Report vulnerabilities through the private process in the root
[security policy](../SECURITY.md).
