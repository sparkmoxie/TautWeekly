# Unified container image, profiles, and migration

TautWeekly v0.23.0 publishes one multi-architecture OCI image for Docker
Desktop, generic Docker Compose, NAS, QNAP, Unraid, FreeBSD/Podman, and
compatible Linux-container systems:

    ghcr.io/sparkmoxie/tautweekly:0.23.0

The image contains the shared application and Manager payload for linux/amd64
and linux/arm64. The host selects a small, validated runtime profile; profiles
change host-facing defaults and reporting, not the private data format.

## Profile contract

| Profile | Intended host | Manager/network contract | Package identity |
|---|---|---|---|
| desktop | Docker Desktop, including Intel and Apple-silicon Macs | Mac Manager mode; loopback-first host publication; named-volume default; host.docker.internal guidance | container-desktop |
| server | Generic Compose, QNAP, NAS, and FreeBSD/Podman | NAS Manager mode; intentional trusted-LAN publication; bind-mount default; PUID/PGID ownership | container-compose, nas-docker, qnap-container-station, docker-compatible, or freebsd-podman |
| unraid | Maintained Unraid Community Applications template | NAS Manager mode; trusted-LAN publication; Unraid appdata and Apps-owned lifecycle | unraid |

Set TAUTWEEKLY_RUNTIME_PROFILE explicitly in new deployments. The container
refuses an unknown profile or an incompatible profile/package combination with
exit status 64 before the Manager or scheduler starts. Existing v0.22.0
definitions that omit the variable remain compatible: Mac package identities
infer desktop, Unraid infers unraid, and other supported container identities
infer server. This inference is a migration bridge, not the preferred new
configuration.

A later compatible container system can reuse one of these profiles with its
own package identity and host adapter. Adding a platform does not require a
second application payload or image repository.

## Preferred and fallback routes

The preferred container route is the published unified image plus a
release-checksummed Compose asset, the maintained Unraid template, or a
platform-native container tool that preserves the same contract. Windows
remains a native Manager installation. Native systemd Linux remains preferred
where a native service is wanted. FreeBSD retains its documented Podman beta
route.

The NAS and Mac archives remain supported host-adapter, recovery, and
local-build fallbacks. They are not required for a no-clone registry
installation. Do not replace a working native Windows or Linux installation
with a container merely to follow this consolidation.

## Image references and publication boundary

Use the full release tag for reviewed deployments:

    ghcr.io/sparkmoxie/tautweekly:0.23.0

For unattended automation, append the release manifest digest shown by the
release and registry:

    ghcr.io/sparkmoxie/tautweekly:0.23.0@sha256:<manifest-digest>

The digest is immutable. The full semantic-version tag is the readable stable
default. The minor, latest, and edge tags are mutable and are not recommended
CI/CD promotion references. Unraid may retain latest because its Apps workflow
is explicitly host-owned and digest-aware; administrators should review each
update before applying it.

The release workflow publishes the amd64/arm64 manifest, provenance, and SBOM
before it creates the GitHub release. The release job is gated on the image
job and on checksummed artifact validation, so a GitHub release cannot silently
advertise an image that its workflow failed to publish. Registry publication
and the GitHub release API are not transactional: if the final release call
fails, the semver image may briefly exist first. In that case the maintainer
reruns the failed release job for the same tag and commit; the tag is never
moved to different content.

## Before either migration

1. Record the running image reference, image ID, manifest digest, runtime
   profile, package kind, Compose/template revision, ports, networks, and every
   environment override.
2. Identify exactly what is mounted at /data. It may be a named volume or a
   host bind mount. Do not create a fresh empty mount for the replacement.
3. Back up /data privately while preserving ownership and modes. It contains
   credentials, Manager authentication, schedules, state, output, history,
   cache, and recipient-related information. Keep the backup out of the
   repository and public support reports.
4. For bind mounts, record PUID, PGID, and UMASK. Keep the same non-root numeric
   identity. For named volumes, record the exact volume name.
5. Record the current Manager URL and confirm that the administrator password
   works. The migration preserves the password hash and pairing state.
6. Disable or avoid starting a new delivery during the recreate. A normal stop
   allows up to 30 minutes for an active operation to drain, but a host that
   enforces a shorter hard stop can interrupt it.
7. Pull the new image before removing the healthy old container. A failed or
   interrupted pull leaves the running container and /data unchanged.

Never use docker compose down -v, docker volume rm, or an Unraid appdata delete
during update, migration, rollback, reinstall, or access recovery.

## Migrate the v0.22.0 Mac-specific image

This path starts from
ghcr.io/sparkmoxie/tautweekly-mac:0.22.0, whose release manifest digest was
sha256:982252b1140acf5ee2448668f14fb18683ea27801e218eb09704621232ae03fa.

1. Download TautWeekly-mac-compose.yaml and SHA256SUMS.txt from the v0.23.0
   release and verify the Compose checksum.
2. Compare the new file with the active definition. Preserve the existing
   tautweekly-data named volume or the exact existing bind mount, host port,
   private .env settings, allowed hosts, secure-cookie policy, PUID, PGID,
   UMASK, timezone, and any intentional network attachment.
3. Confirm these new values:

       image: ghcr.io/sparkmoxie/tautweekly:0.23.0
       TAUTWEEKLY_RUNTIME_PROFILE: desktop
       TAUTWEEKLY_PACKAGE_KIND: container-desktop

4. Pull and recreate without deleting the volume:

       docker compose pull tautweekly
       docker compose up -d --no-build --force-recreate tautweekly
       docker compose ps

5. Wait for healthy status. Open http://localhost:8787/, sign in with the
   existing Manager password, and confirm Settings > Updates reports the
   unified repository, desktop profile, current stable version, and host-owned
   Docker Desktop lifecycle.
6. Run Validate, save, and verify, inspect all six previews, and send only the
   controlled TestEmail before accepting the migration. The existing schedule,
   configuration, history, and pairing state should already be present.

For Mac-hosted Plex or Tautulli, continue to use host.docker.internal. Container
localhost still refers to TautWeekly. The desktop Compose default publishes the
Manager only on 127.0.0.1. Set PREVIEW_BIND=0.0.0.0 only for intentional trusted
LAN access, retain Manager authentication, and use an exact-host TLS proxy for
remote access.

To roll back, restore the prior Compose file or set the recorded old image
reference, keep the same /data volume, and recreate. Do not restore an older
data backup unless the release notes identify an incompatible data change or
the current data itself is damaged.

## Migrate the v0.22.0 NAS or generic image

This path starts from ghcr.io/sparkmoxie/tautweekly:0.22.0. The repository name
does not change; the explicit profile and semver-pinned release Compose asset
are the important changes.

1. Download TautWeekly-compose.yaml and SHA256SUMS.txt from the v0.23.0 release
   and verify the checksum, or refresh the verified NAS/QNAP host package.
2. Preserve the exact existing bind-mounted data directory or named volume,
   PUID, PGID, UMASK, timezone, port/bind settings, allowed hosts, secure-cookie
   policy, and Docker networks.
3. Confirm the new generic/QNAP definition uses:

       image: ghcr.io/sparkmoxie/tautweekly:0.23.0
       TAUTWEEKLY_RUNTIME_PROFILE: server
       TAUTWEEKLY_PACKAGE_KIND: container-compose

   A QNAP package may retain qnap-container-station and the NAS archive may
   retain nas-docker as package identity; both are compatible with server.
4. Pull, recreate with the original deployment tool, and wait for health:

       docker compose pull tautweekly
       docker compose up -d --no-build --force-recreate tautweekly
       docker compose ps

5. Open the existing trusted-LAN Manager URL, sign in with the existing
   password, and confirm Settings > Updates reports server plus the unified
   repository. Repeat Manager verification, six previews, and TestEmail.

Server and Unraid profiles intentionally retain trusted-LAN guidance. Container
localhost is not the NAS host. Use a shared private Docker network, a reachable
NAS/LAN address, or the platform's supported host gateway. Never public-forward
the Manager's plain HTTP port.

## Migrate or refresh Unraid

Update the saved Community Applications template before applying the image
update. Preserve the existing appdata path, WebUI port, PUID, PGID, UMASK,
timezone, allowed-host and secure-cookie settings. Confirm the hidden Runtime
profile is unraid and Package kind remains unraid. Apply the update from
Unraid Docker/Apps, wait for healthy status, then sign in and run the same
Manager acceptance sequence. Do not delete appdata and do not add privileged
mode, root identity, a Docker socket, or a TUN device.

## Named-volume and bind-mount permission checks

A named volume is owned from inside the container using the configured non-root
identity. Back it up with a trusted temporary container or host tool that
preserves numeric ownership and file modes.

For a bind mount, the host directory must be writable by PUID:PGID. Keep
UMASK=077 unless a documented integration requires another restrictive value.
The entrypoint may repair legacy root-owned entries within /data but refuses
PUID or PGID 0 and does not follow symlinks out of the data filesystem. If a
host ACL prevents repair, stop the container and correct that exact data
directory from the trusted host; do not grant broad root or privileged access.

## Interrupted pull, recreate, and recovery

- Interrupted pull: rerun the pull. Do not remove the healthy running
  container merely because a new manifest is incomplete.
- Interrupted recreate before replacement starts: rerun the same host-owned
  recreate against the same /data mount.
- New container unhealthy: inspect the production health result and recent
  sanitized logs, verify profile/package compatibility and permissions, then
  recreate with the recorded prior semver/digest.
- Manager asks for first-run pairing unexpectedly: stop. Verify that the
  original /data volume or bind mount is attached. Do not create a new password
  in an empty replacement volume.
- Forgotten password with the correct data attached: use access-recover,
  restart, retrieve a new one-time bootstrap token explicitly, and pair again.
  This removes only Manager access material; it preserves configuration,
  schedules, state, output, backups, and history.
- Interrupted delivery: inspect the sanitized operation and scheduler state
  after recovery before manually retrying. Do not assume a process exit means
  mail was or was not accepted.

## Old Mac image retirement and compatibility window

ghcr.io/sparkmoxie/tautweekly-mac:0.22.0 remains a documented rollback source
and is not deleted or retagged. No v0.23.0 or later release is published to that
repository, and it is no longer recommended for new installs.

TautWeekly-mac-compose.yaml remains a transitional release asset through the
v0.23.x and v0.24.x lines. It points to the unified image and selects desktop;
it is not a second image payload. It may be retired no earlier than v0.25.0,
and only with release-note notice. The canonical generic asset is
TautWeekly-compose.yaml. Existing archive/local-build Mac installations remain
a supported break-fix path during this window and retain their data-preserving
host updater and rollback behavior.

The Manager never receives a Docker socket, container-engine credentials, or a
host update helper. Settings reports the unified image, active profile,
migration state, stable release, semver/digest recommendation, and recovery
steps; the host administrator or platform UI always performs the update.
