# Remote access architecture and platform support

TautWeekly v0.25.0 uses one maintained remote-access architecture: optional
public HTTPS through Tailscale Funnel. Remote viewers open the generated
`.ts.net` URL in an ordinary browser and need neither Tailscale nor a VPN.
The Manager password lock is mandatory whenever Funnel is selected.

Manager remains local to its package boundary. Native packages listen only on
loopback. Container packages keep the Manager in their isolated network
namespace and map the recovery port to host loopback by default; Funnel proxies
only the fixed in-container `http://127.0.0.1:8080` target. TautWeekly never
opens a router/firewall port or accepts a browser-selected target.

## Maintained package inventory

| Maintained surface | Fixed Manager target | Funnel adapter and lifecycle owner |
|---|---|---|
| Windows 10/11 Setup and portable package | `http://127.0.0.1:8788` | Unelevated Manager plus the signed fixed UAC helper and the separately installed official Windows client |
| Ubuntu, Debian, and RHEL-family systemd package | `http://127.0.0.1:8788` | Unprivileged Manager plus the root-owned one-shot Unix-socket adapter and the separately installed official Linux client |
| Generic Docker/NAS and standalone Compose | `http://127.0.0.1:8080` inside the container | Non-root Manager plus the opt-in isolated userspace adapter shipped in the unified image |
| QNAP Container Station and Synology/other Docker-capable NAS installs | Same fixed container target | Same unified-image userspace adapter; NAS tooling owns the container |
| Unraid Community Apps | Same fixed container target | Same unified-image userspace adapter; Unraid Apps owns the container |
| macOS Docker Desktop, Intel and Apple silicon | Same fixed container target | Same unified-image userspace adapter; Docker Desktop owns the container |
| FreeBSD 15.1+ Podman beta | Same fixed Linux-container target | Same unified-image userspace adapter; the FreeBSD rc.d/Podman wrapper owns the container |

There is no maintained native macOS, native QNAP/Synology, or native FreeBSD
Manager. The table follows the packages actually built by the release workflow
and does not invent support for retired distributions.

## Shared controller and threat boundary

The shared controller is provider-neutral even though this release adds only a
Tailscale adapter:

1. The authenticated browser API accepts only `enable`, `disable`, and the
   separate fixed `verify` endpoint. JSON with a URL, hostname, port, path,
   executable, command, argument, or extra field is rejected.
2. The backend owns the fixed local target, exact route match, schema-versioned
   preference, password gate, Host admission, public verification, and
   fail-closed cleanup.
3. Platform adapters return only sanitized states. Raw CLI output, tailnet
   identity, device lists, private addresses, DNS answers, certificate details,
   auth material, and sensitive paths never cross into the browser, diagnostics,
   or Manager data.
4. A legacy exact TautWeekly Serve route may be detected only for migration.
   Explicit Enable converts that exact owned route to Funnel; Disable removes
   it. Serve cannot be newly configured through the browser or any maintained
   package deployment.

The current official CLI operations are fixed to Funnel HTTPS port 443 and the
package target. A conflicting route, malformed/stale response, signed-out or
stopped client, missing authorization, unsupported client, or unexpected target
fails closed.

## Container and NAS adapter

The unified image pins the official `tailscale/tailscale:v1.102.2` runtime and
copies only its `tailscale` and `tailscaled` binaries. The adapter:

- is disabled unless `TAUTWEEKLY_FUNNEL_ADAPTER=enabled`;
- runs `tailscaled` in userspace mode with no TUN device, host networking,
  privileged mode, added networking capability, Docker/Podman socket, or host
  executable;
- stores provider state in the separate root-owned
  `/var/lib/tautweekly-tailscale` volume, outside `/data`;
- refuses auth-key, OAuth-client, token, and auth-file environment inputs;
- requires an explicit interactive console login;
- exposes a mode-0600 Unix socket only to the configured non-root Manager UID;
  and
- accepts only inspect, enable, or disable for the fixed in-container target.

Shipping the declared official runtime in the image is not a silent host
installation. TautWeekly never signs in, creates an account, stores an auth key,
or logs out another identity. Provider authentication remains a deliberate host
administrator action.

| Package | Explicit login command after enabling the adapter |
|---|---|
| Generic Compose, NAS, QNAP/Synology, macOS Docker | `./tautweekly.sh remote-access-login` |
| Unraid | Container Console: `/opt/tautweekly/bin/tautweekly-funnel login` |
| FreeBSD/Podman | `sudo tautweekly remote-access-authorize` |

## Public state and admission

    Off -> Configured locally / Publication pending -> Active
                 |                               |
                 +---- conflict or invalid ------+----> Needs attention

**Active** requires, in the same explicit verification:

- an active Manager password lock;
- exact ownership of HTTPS port 443, the single fixed proxy target, and Funnel
  permission;
- a valid generated `.ts.net` hostname;
- public DNS queried through the fixed public resolver with non-public answers
  rejected; and
- a certificate-validated TLS handshake made directly to a public answer with
  the expected hostname as SNI.

A locally configured route without both public DNS and trusted TLS remains gold
**Publication pending**. Manager admits the public Host only after the verified
hostname and publication result are persisted. Remote requests retain exact
Host/origin checks, Secure/HttpOnly/SameSite cookies, CSRF, session continuity,
logout, secret boundaries, no-index behavior, and sanitized diagnostics.
Funnel adds no read-only role and this release adds no login rate limiter, so a
unique Manager password remains essential.

### Retained Dashboard status

The Dashboard Integrations card shows Tailscale Funnel directly below SMTP
without running a provider command or an independent verification. It reuses
the authenticated, sanitized typed state retained by the Manager and renders
only fixed copy:

| Retained state | Dashboard row | Integrations aggregate |
|---|---|---|
| Exact route is safely off | **Passed** with **Off** supporting text | Pass contribution |
| Exact route plus public DNS and trusted TLS are verified | **Passed** with **Active** supporting text | Pass contribution |
| Exact local route is configured but publication is not proven | Gold **Attention** with **Publication pending** | Attention contribution |
| Password lock is missing while enabled, route/state is inconsistent, or cleanup is incomplete | **Failed** with **Blocked** supporting text | Fail contribution |
| Surface is unsupported or the optional adapter is genuinely not configured | Neutral informational text | No contribution |

The row links to **Settings > Tailscale Funnel** when that panel applies. It
never displays the public hostname or URL, provider output, identity, device
data, private address, token, command, argument, port, target, or state-file
path.

The host administrator must satisfy Tailscale's current Funnel prerequisites:
MagicDNS, HTTPS certificates, and a `funnel` node attribute targeting the
actual node identity. TautWeekly neither reads nor edits tailnet policy, tags,
devices, DNS, or authentication state.

## Lifecycle rules

- Password-lock disable, access reset/recovery, explicit stop, update, rollback
  preparation, adapter revocation, and uninstall first disable and verify only
  the exact owned Funnel. Failure preserves the password/application boundary
  and stops the requested action.
- Windows and native Linux ordinary Manager restarts may preserve an already
  selected route. Their explicit stop/update/recovery paths leave Funnel off for
  deliberate re-enable.
- Container stop, recreate, update, and recovery ask the running Manager to
  disable and verify Funnel before the adapter exits. The next container starts
  with Funnel off until explicitly re-enabled; provider state and Manager data
  remain separate and preserved.
- An abrupt host power loss or forced `SIGKILL` cannot run any package cleanup.
  The isolated proxy process stops with the container; on recovery, verify the
  saved state before re-enabling.
- Password changes preserve Funnel and the current session while revoking other
  sessions.

## Publication acceptance and upstream limitations

Local `Funnel on` is never accepted as proof of publication. Open upstream
reports document local-success/public-failure classes on Windows, Linux, and
containers:

- [tailscale/tailscale#19508](https://github.com/tailscale/tailscale/issues/19508)
- [tailscale/tailscale#11849](https://github.com/tailscale/tailscale/issues/11849)
- [tailscale/tailscale#8680](https://github.com/tailscale/tailscale/issues/8680)
- [tailscale/tailscale#19290](https://github.com/tailscale/tailscale/issues/19290)

These reports are evidence, not operational instructions. Do not create a
manual A record, open a router/firewall port, repeatedly reset certificates, or
replace the transport to force an Active state. Tailscale documents a
propagation window; after it, the route still remains pending until both
independent checks pass.

The accepted Windows validation reached green **Active** with the required
password lock and exact loopback target. That proves one host and hostname, not
that the upstream failure classes are resolved on every platform. All other
package rows use synthetic DNS/TLS fixtures and virtual lifecycle tests until
live host acceptance is performed.

Official provider references:

- [Tailscale Funnel](https://tailscale.com/kb/1223/funnel)
- [Tailscale Funnel CLI](https://tailscale.com/docs/reference/tailscale-cli/funnel)
- [Tailscale in Docker](https://tailscale.com/kb/1282/docker)
- [Tailscale targets and selectors](https://tailscale.com/docs/reference/targets-and-selectors)
- [Tailscale device tags](https://tailscale.com/docs/features/tags)
