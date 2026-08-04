# NAS / Docker Compose installation

[Open the rendered interactive NAS walkthrough](https://sparkmoxie.github.io/TautWeekly/nas-docker/)
· [Open the rendered Compose quick start](https://sparkmoxie.github.io/TautWeekly/nas-docker/quickstart.html)

This distribution runs TautWeekly for Plex as a dedicated Docker Compose service beside
Tautulli. It targets QNAP Container Station, Unraid, and general Linux Docker
hosts on x86-64 or ARM64.

Current source baseline: **1.1.0**.

## Requirements

- Docker Engine and Docker Compose v2, or a compatible vendor Compose UI.
- A non-root UID and GID that can write the project `data/` directory.
- Network access from the container to Tautulli and an SMTP STARTTLS endpoint.
- A Tautulli API key.
- A trusted host port for the local preview service; default 8787.

## Install from Unraid Apps

In Unraid Community Applications, search for **TautWeekly for Plex**, review
the port and appdata path, and select **Install**. The maintained template is
[`templates/tautweekly.xml`](../../templates/tautweekly.xml) and pulls
`ghcr.io/sparkmoxie/tautweekly:latest` for amd64 or arm64 automatically.

After installation, open **Docker > TautWeekly for Plex > Console** and run:

```bash
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Verify-Setup.ps1
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-User-Exclusions.ps1
/opt/tautweekly/bin/run-mode.sh ListUsers
/opt/tautweekly/bin/run-mode.sh PreviewAll
```

Open `http://UNRAID_HOST:8787/preview-all/preview-all-00-INDEX.html` and review
every state before sending a TestEmail or enabling the schedule. Port 8787 is
a private LAN preview service; never expose it to the public internet.

Community Applications listings are moderated. The template can be audited
directly from its [raw URL](https://raw.githubusercontent.com/sparkmoxie/TautWeekly/main/templates/tautweekly.xml).
See the official [Unraid submission requirements](https://ca.unraid.net/submit/help)
and [repository XML format](https://ca.unraid.net/submit/help/repository-xml).

## Install on QNAP Container Station

QNAP's Docker-native path is **Container Station > Create Application**. Paste
[`compose.qnap.yaml`](../../platforms/nas-docker/compose.qnap.yaml), change the
timezone and non-root PUID/PGID, and confirm the host data path before creating
the application. QNAP documents Compose applications in Container Station;
App Center repositories distribute native QPKG applications instead, so this
Docker edition is not presented as a QPKG.

References: [QNAP Container Station application creation](https://docs.qnap.com/operating-system/qne-network/1.0.x/en-us/container-creation-1A95801A.html)
and [QNAP App Center repository settings](https://docs.qnap.com/operating-system/qts/5.0.x/en-us/app-center-settings-8C55F8A1.html).

The guided SSH installer remains available from the release archive:

```bash
./qnap-install.sh
```

## Install from a release on another Docker host

Download the latest
[`TautWeekly-nas-docker.tar.gz`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.tar.gz)
or [ZIP archive](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.zip),
then extract one format:

```bash
tar -xzf TautWeekly-nas-docker.tar.gz
cd TautWeekly-nas-docker
chmod +x qnap-install.sh tautweekly.sh app/*.sh app/bin/*.sh
```

For a general Docker host, use the portable Compose workflow:

```bash
cp .env.example .env
# Edit .env: timezone, UID/GID, preview bind, and preview URL.
docker compose pull
docker compose up -d
./tautweekly.sh setup
./tautweekly.sh verify
./tautweekly.sh exclude-users
```

Use a hostname reachable from inside the container, for example
`http://media.example.test:8181`. Do not use `127.0.0.1` for Tautulli unless it
runs in the same container, which is not the supported deployment model.

## Safe acceptance sequence

```bash
./tautweekly.sh verify
./tautweekly.sh list-users
./tautweekly.sh exclude-users
./tautweekly.sh preview-all
./tautweekly.sh send-test-all
./tautweekly.sh schedule-status
```

During preview review, confirm the adaptive one-item cards, movie genres,
Binge Champion winner disclosure, and counted Trending section.

Only after the previews and controlled TestEmail messages are approved:

```bash
./tautweekly.sh schedule-enable
```

`welcome` and `send-all` target real Plex users and require interactive
confirmation.

## Manage user exclusions

Primary setup queries Tautulli after the URL and API key are entered. Select
comma-separated rows or ranges such as `2,4-6`; press Enter to keep the current
selection or type `none` to clear it. The stable IDs are saved in
`ExcludedUserIds`.

Run `./tautweekly.sh exclude-users` whenever the recipient policy changes.
Unraid Apps users can instead run this from the container Console:

```bash
pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-User-Exclusions.ps1
```

The command changes only `ExcludedUserIds`; manually maintained
`ExcludedEmails` entries are preserved. Excluded users are skipped by the
scheduler and SendAll. Preview/TestEmail modes and the separately confirmed
one-off welcome remain explicit administrator tools. Treat the displayed
names and email addresses as private recipient data.

## Networking

The default Compose file publishes container port 8080 as host port 8787. Set
`PREVIEW_BIND=127.0.0.1` for host-only access or bind to a trusted LAN interface
when remote preview access is required. Never port-forward this service to the
public internet.

When TautWeekly for Plex and Tautulli share a user-defined Docker network, a service URL
such as `http://tautulli:8181` is appropriate. Otherwise, use a DNS name the
container can resolve.

## Persistent data

The relative bind mount `./data:/data` contains configuration, state, logs,
assets, and generated output. It is excluded from git and Docker build context.

Create a private backup with:

```bash
./tautweekly.sh backup
```

The backup contains credentials. Store it as securely as the live
configuration.

## Lifecycle commands

```bash
./tautweekly.sh status
./tautweekly.sh logs
./tautweekly.sh restart
./tautweekly.sh update
./tautweekly.sh schedule-disable
docker compose down
```

See [configuration](../CONFIGURATION.md), [security](../SECURITY.md), and
[troubleshooting](../TROUBLESHOOTING.md).
