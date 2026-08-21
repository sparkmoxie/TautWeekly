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
storage. Manager and expert/recovery writers retain the newest 10 recognized
timestamped backups and remove the oldest on overflow. Manager **Config > Configuration
backups** exposes only metadata. Restore validates the selected file and first
saves the live configuration. Delete accepts only the exact Manager-listed
backup filename, refuses symlinks/non-files, requires an authenticated
same-origin CSRF-protected request plus a separate browser confirmation, and
permanently removes only that backup. It never changes `config.json`.

Custom-title GIF configuration accepts only six fixed asset IDs. IDs map to
packaged byte-verified filenames, `image/gif` MIME types, and deterministic CIDs;
paths, URLs, filenames, arbitrary MIME types, and arbitrary CIDs are rejected.
Email attaches only the selected referenced asset, and the Manager serves the
same local files without a runtime font or network dependency.

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

- NAS/Docker, macOS Docker Desktop, native Linux, and FreeBSD Podman require
  Manager authentication.
  There is no default password. Retrieve a random first-run token only through
  the platform's explicit `manager-bootstrap` command; it is intentionally
  absent from normal logs and diagnostics.
- The Manager uses HttpOnly SameSite cookies, per-session CSRF tokens,
  same-origin mutation checks, bounded sessions, and login throttling. A
  service restart invalidates sessions without changing newsletter delivery
  state. Access recovery resets only Manager authentication material.
- Keep NAS/FreeBSD/macOS Manager port 8787 and native Linux Manager port 8788
  off the public internet. Prefer the documented localhost bind or a trusted
  LAN bind restricted by the host firewall. macOS binds to Mac loopback by
  default; changing that bind requires the same explicit allowed-host and TLS
  review as any other network-reachable Manager.
- Optional Tailscale support uses private HTTPS Serve, never public Funnel.
  Windows verifies a fixed route through an explicit UAC helper; native Linux
  uses a root-owned, socket-activated helper that verifies the fixed service UID
  and exposes only Inspect/Enable/Disable for the fixed loopback target. All
  container/host-managed packages accept only one exact HTTPS `.ts.net`
  hostname after an authenticated administrator confirms the external route is
  private and Funnel is off. They never accept a Tailscale credential or gain a
  Docker/Podman/host control plane.
- Treat tailnet membership as an additional network boundary, not Manager
  authentication. Non-Windows packages keep their independent Manager password
  required; the Windows password lock remains optional. Every remote session
  has full Manager administration because no read-only role exists. Restrict
  tailnet grants, use MFA at the identity provider, protect and promptly revoke
  lost devices, keep clients updated, and retain local/host recovery access.
- A saved external Tailscale address means Manager will accept that exact Host;
  it does not prove the host-owned route is still present or private. Recheck
  Serve and Funnel state after host/client updates. Disable in Manager first so
  the hostname is blocked immediately, then remove the external route. Never
  expose or retain auth keys in Manager, Compose YAML, `.env`, Community Apps
  templates, screenshots, logs, or support bundles.
- For a trusted TLS reverse proxy, allow only its exact DNS host, preserve the
  original Host header, and enable secure Manager cookies. Do not trust broad
  wildcards or publish the plain HTTP backend. Remove proxy Host rewrites,
  including a Cloudflare Tunnel `httpHostHeader` override; never allowlist the
  rewritten backend address as a workaround. The Manager does not infer TLS or
  client identity from forwarded headers. Same-origin comparison
  lower-cases DNS, removes one trailing dot, and normalizes omitted/default
  `:80` or `:443`; malformed origins, different hosts, and Tailscale HTTP
  mutations remain rejected with sanitized reason codes.
- Unauthenticated health endpoints expose liveness only. They do not return
  configuration, credentials, sessions, paths, diagnostics, or newsletter
  state.
- Normal Manager/Dashboard health and `GET /api/v1/updates` are offline-only.
  After authenticated application entry renders that cached result, the GUI
  makes one non-blocking check only when no successful result exists or it is at
  least 24 hours old and retry backoff permits. Successful results are reused
  for five minutes before **Check now** can use the same endpoint for another
  explicit refresh. Both paths use a fixed HTTPS GitHub
  endpoint, reject redirects and unexpected hosts/assets, bound time and
  response size, cache only public release fields plus fixed sanitized
  failures, and back off repeated checks. The login/bootstrap page, navigation,
  and health endpoints never initiate a check. Update mutations require the
  same session, same-origin, CSRF, Host, proxy, and secure-cookie controls as
  every other protected Manager action.
- Only Windows exposes a GUI install action, and it can start only the fixed
  packaged checksum/manifest-verified updater behind explicit confirmation and
  Windows elevation. Container/native service Managers never receive a Docker
  socket, privileged helper, root identity, `sudo`, Podman, systemd, or rc.d
  authority; Settings reports the exact host-owned next step instead.
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
