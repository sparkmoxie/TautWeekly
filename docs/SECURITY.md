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

## Deleted-item cache

The persistent cache is private media-library data even though it contains no
credentials or recipient records. It stores exact stable media GUIDs, titles,
years, bounded summaries and genres, displayed rating values, poster bytes and
hashes, and timestamps. It deliberately excludes Tautulli API keys, the Plex
administrator token, SMTP settings, recipient identity, playback metrics, and
generated newsletter output. The Plex token is never passed into the cache.

Cache locations are `cache/deleted-items` beside the Windows application,
`/data/cache/deleted-items` in Docker/macOS, `/var/lib/tautweekly/cache/deleted-items`
on native Linux, and `/var/db/tautweekly/cache/deleted-items` on FreeBSD. Apply
the same filesystem permissions and backup protections as `config.json`.
Exact GUID plus media type is the only lookup identity; title-only and malformed
manifest entries fail closed. Posters are verified by SHA-256 before reuse.

Retention defaults to 365 days, 1,000 items, and 256 MiB total. Deterministic
cleanup, atomic primary/backup manifests, a one-megabyte corrupt-manifest cap,
and orphan removal keep storage bounded. To purge without changing
configuration, stop the service/application and remove only this directory.
Disabling the feature stops access but does not erase the existing cache.

## Network boundaries

- Keep preview port 8787 off the public internet.
- Prefer localhost binding when previews are consumed on the same host.
- If LAN binding is required, restrict inbound access with the host firewall.
- Use HTTPS for remote Tautulli/Plex endpoints when your environment provides a
  trusted TLS reverse proxy.
- Best-effort hosted deleted-item recovery sends only Tautulli's retained exact media GUID and the
  configured administrator/server Plex token to
  `https://metadata.provider.plex.tv`. It sends no recipient identity, email,
  or watch-history values and does not perform title searches.
- Hosted recovery cannot reliably reconstruct artwork already discarded by
  Plex/Tautulli. The persistent cache protects future items only after a live
  run captured them; it does not create a retroactive title-matching path.
- Hosted artwork returned on a different origin is fetched without the Plex
  token. The token is attached only to Plex server and Plex metadata-provider
  requests.
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
