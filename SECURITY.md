# Security policy

TautWeekly for Plex handles SMTP credentials, a Tautulli API key, and optionally a Plex
token. Treat every live configuration file and backup as a secret-bearing
artifact.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
**Security → Report a vulnerability** flow for this repository so details can
be reviewed privately.

Include the affected platform, version or commit, reproduction steps, impact,
and any suggested mitigation. Do not include real credentials, tokens, server
addresses, recipient data, or generated newsletters.

## Supported versions

The latest release and `main` receive security updates; older distributions are
supported on a best-effort basis. FreeBSD Podman support is currently beta and
requires host acceptance testing before scheduled use.

## Operator responsibilities

- Keep `config.json`, `.env`, state files, the deleted-item cache, logs,
  previews, and backups private.
- Use provider-specific application passwords where available.
- Bind the preview service to localhost unless LAN access is intentional and
  protected by host firewall rules.
- Never expose preview port 8787 directly to the public internet.
- For optional remote Manager administration, use private Tailscale Serve with
  Funnel off or a deliberately hardened HTTPS proxy. Tailnet access does not
  replace the Manager login, and every remote session has full administration.
- Preview and test with a controlled recipient before enabling scheduled sends.
- Revoke and replace any credential that may have entered a commit, log, issue,
  or release archive.

See [the security guide](docs/SECURITY.md) for platform-specific hardening.
