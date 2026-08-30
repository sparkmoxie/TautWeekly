# Remote access architecture and platform support

This document describes the v0.25.0 remote-access boundary. Manager always
listens on its package-defined local address. Public ingress, when supported,
is an official Tailscale Funnel proxy to that fixed loopback target; TautWeekly
does not open a firewall or router port, bind Manager broadly, install or
authenticate Tailscale, or accept a Tailscale credential.

## Maintained package inventory

| Maintained surface | Manager runtime | Supported remote-access mode | Lifecycle owner |
|---|---|---|---|
| Windows 10/11 Setup and portable package | Native Windows, 127.0.0.1:8788 | Integrated public Funnel | Unelevated Manager plus the fixed UAC helper |
| Ubuntu, Debian, and RHEL-family systemd package | Native Linux, 127.0.0.1:8788 | Integrated public Funnel | Unprivileged Manager plus the root-owned one-shot socket adapter |
| Generic Docker/NAS and standalone Compose | Unified container, mapped port 8787 by default | External private Serve only | Host administrator or optional official userspace sidecar |
| QNAP Container Station and Synology/other Docker-capable NAS installs | Unified container | External private Serve only | NAS vendor client or host administrator |
| Unraid Community Apps | Unified container, unraid profile | External private Serve only | Unraid Tailscale Plugin and host administrator |
| macOS Docker Desktop, Intel and Apple silicon | Unified container, desktop profile | External private Serve only | macOS host client or optional private sidecar |
| FreeBSD 15.1+ Podman beta | Unified Linux container | External private Serve only | Community-maintained FreeBSD host client and administrator |

There is no maintained native macOS Manager, native QNAP/Synology Manager, or
native FreeBSD Manager. The table follows the packages actually built by the
release workflow and does not create support for retired surfaces.

Container packages deliberately refuse integrated public Funnel. Manager has
no Docker socket, host executable, host network, privileged mode, root
identity, auth key, or vendor control plane. It therefore cannot prove that it
owns the public route or disable and verify that route before password reset,
shutdown, rollback, or uninstall. A separately administered private Serve
route is the supported boundary; public Funnel is not offered through Manager
or the bundled sidecar.

## Shared controller and adapters

The public implementation has a provider-neutral controller boundary and a
Tailscale adapter:

1. The authenticated browser API accepts only typed enable, disable, and
   verify operations. It cannot supply an executable, command, CLI argument,
   port, hostname, target, path, or provider output.
2. The shared controller owns the fixed loopback target, exact route
   postconditions, schema-versioned state, password gate, Host admission, and
   fail-closed cleanup. A future provider must satisfy this same contract; the
   delivery does not add another transport.
3. The Windows adapter resolves only the official installed CLI and sends one
   fixed operation to the signed package helper through UAC. The native Linux
   adapter sends the same narrow operation over a protected Unix socket to a
   root-owned one-shot service. The Linux service accepts only the installed
   tautweekly service UID and the exact target.
4. Provider status is parsed into a sanitized observation. Raw CLI output,
   tailnet identity, device lists, private addresses, auth material, and
   sensitive paths never cross the adapter boundary or enter diagnostics.

The current official CLI form is a background HTTPS Funnel on port 443 to the
fixed loopback target. Exact inspection and disable operations use the
provider's current Funnel status/off semantics. A conflicting route, malformed
or stale response, missing CLI, signed-out client, unsupported client, missing
host authorization, or unexpected target fails closed.

## Public state and admission

Public state moves through these observable states:

    Off -> Configured locally / Publication pending -> Active
                 |                               |
                 +---- conflict or invalid ------+----> Needs attention

Active requires all of the following in the same explicit verification:

- an active Manager password lock;
- the exact HTTPS port, TCP target, single web handler, and Funnel permission;
- the expected .ts.net hostname;
- public DNS queried through the fixed public resolver, with non-public answers
  rejected; and
- a trusted TLS handshake made directly to a public answer with the expected
  hostname as SNI.

A locally configured route without public DNS or trusted TLS remains gold
**Publication pending**. Manager admits the public Host only after the verified
hostname and publication state are persisted. Remote requests retain exact
Host/origin comparison, Secure/HttpOnly/SameSite cookies, CSRF, session and
logout behavior, no-index metadata, and the package's existing authentication
and login-throttling behavior. Funnel adds no read-only role and no additional
Internet rate limiter.

The host administrator must satisfy Tailscale's current prerequisites before
publication: MagicDNS, valid HTTPS certificates, and a `funnel` node attribute
that actually targets the node. The default `autogroup:member` example targets
member-owned devices. A tagged container, Kubernetes, or other service node has
a tag identity instead of a user identity, so its policy needs an explicit
tag-targeted `nodeAttrs` entry. TautWeekly neither reads nor edits tailnet
policy, tags, device identity, or auth state. This warning does not make those
container surfaces integrated or supported for public Funnel.

The container-specific evidence in
[tailscale/tailscale#11849 comment 2211623437](https://github.com/tailscale/tailscale/issues/11849#issuecomment-2211623437)
shows that a declarative tagged sidecar needs both an `AllowFunnel` entry set to
true for `${TS_CERT_DOMAIN}:443` and a `funnel` node attribute targeting the
actual container tag, such as `tag:containers`. TautWeekly's shipped NAS and
macOS sidecar config intentionally omits `AllowFunnel` and ships no tailnet
policy. Adding only one of those inputs is neither a complete provider setup nor
a lifecycle TautWeekly can own, so integrated public Funnel remains refused.
This container-only requirement does not apply to an untagged member-owned
Windows device and is not a reason to edit Windows Tailscale state or tag that
device.

## Lifecycle rules

- Startup and an ordinary restart preserve the selected public preference.
- Password-lock disable, local access reset, explicit stop, adapter revocation,
  update, recovery, and uninstall first disable and verify the exact owned
  public route. If verification fails, the security boundary or package action
  stays in place.
- Windows and native Linux updates preserve private Manager data, but first
  disable and verify the route and leave Funnel off for explicit re-enable.
- Legacy exact private Serve state on Windows or native Linux is never silently
  treated as public. The integrated controller requires explicit migration or
  verified cleanup.
- External private packages block the saved hostname immediately when disabled
  in Manager; the host administrator then removes the independently owned
  private Serve route. Package removal cannot claim control of that route.

## Publication acceptance

Local `Funnel on` is insufficient on every platform. Current open upstream
reports cover multiple independent failure classes:

- [tailscale/tailscale#19508](https://github.com/tailscale/tailscale/issues/19508):
  Windows records the local Funnel while public DNS remains unavailable.
- [tailscale/tailscale#11849](https://github.com/tailscale/tailscale/issues/11849):
  Linux/iOS and later Docker reports remain reachable only inside the tailnet
  or fail public name resolution.
- [tailscale/tailscale#8680](https://github.com/tailscale/tailscale/issues/8680):
  Docker/Raspberry Pi userspace networking lacks public DNS after the documented
  propagation window.
- [tailscale/tailscale#19290](https://github.com/tailscale/tailscale/issues/19290):
  Linux public DNS resolves, but CDN-edge TLS stalls while in-tailnet access
  succeeds.

These reports are failure evidence, not operational instructions. They do not
authorize a manual DNS record, another provider, or weaker verification.
Do not create an A record, open a firewall/router port, repeatedly reset
certificates, replace the transport, or report the Funnel active to work around
those states. Tailscale documents up to 10 minutes for public DNS propagation;
after that window, a route still remains pending until both independent checks
pass. Merge and release remain gated on real Windows public DNS and trusted-TLS
acceptance plus the live matrix in the v0.25.0 release notes.

Official provider references:

- [Tailscale Funnel](https://tailscale.com/kb/1223/funnel)
- [Tailscale targets and selectors](https://tailscale.com/docs/reference/targets-and-selectors)
- [Tailscale device tags](https://tailscale.com/docs/features/tags)
- [Tailscale Serve and Funnel CLI](https://tailscale.com/kb/1242/tailscale-serve)
- [Tailscale in Docker](https://tailscale.com/kb/1282/docker)
- [Tailscale package variants for macOS](https://tailscale.com/kb/1065/macos-variants)
- [Tailscale on Synology](https://tailscale.com/kb/1131/synology)
- [Tailscale on QNAP](https://tailscale.com/kb/1273/qnap)
- [Tailscale on Unraid](https://tailscale.com/kb/1331/unraid)
