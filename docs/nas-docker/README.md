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

Open `http://UNRAID_HOST:8787/` to confirm the preview service and review its
first-run instructions. After `PreviewAll` completes, open
`http://UNRAID_HOST:8787/preview-all-00-INDEX.html` and review every state
before sending a TestEmail or enabling the schedule. Port 8787 is a private,
read-only preview viewer—not an administration Web UI. Never expose it to the
public internet.

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
anonymous Binge Champion movie/TV/time aggregate, gold winner treatment, and
counted Trending section.

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

The selector joins Tautulli's bulk `get_user_names` and `get_users` responses
by stable ID instead of making one `get_user` request per row. A name-only row
remains selectable if its detailed bulk record is unavailable.

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

The server root always provides a small status and onboarding page. It does
not expose configuration, credentials, send controls, or scheduler controls.
Generated previews appear only after running `preview` or `preview-all`.

## First-run and connection troubleshooting

The only supported persistent configuration location inside the container is
`/data/config.json`. With the supplied Compose files it maps to
`./data/config.json` beside `compose.yaml`; with Unraid it maps into the
configured appdata directory. Editing `/opt/tautweekly/config.json` does not
configure the scheduler and that container-layer file would be lost on update.

If the browser reports **connection refused**:

```bash
./tautweekly.sh status
./tautweekly.sh logs
docker compose port tautweekly 8080
docker compose exec tautweekly tail -n 40 /data/logs/preview-server.log
```

Confirm the container is running and healthy, the published host port is the
one used in the browser, and a firewall is not blocking that host port. Use a
real host name or address in the browser—not Docker's `*:8787` port-listing
notation. The container now exits with a clear error if its preview server
cannot bind, allowing the restart policy and health status to expose the
failure.

If logs say they are waiting for `/data/config.json`, run
`./tautweekly.sh setup` from the extracted Compose directory. In Unraid, use
the exact `Setup-First.ps1` command shown above from the container Console.
Running the container alone does not authorize delivery: setup creates the
configuration, previews are generated on request, and scheduling stays off
until `schedule-enable` is confirmed.

## Persistent data

The relative bind mount `./data:/data` contains configuration, state, logs,
assets, and generated output. It is excluded from git and Docker build context.

Create a private backup with:

```bash
./tautweekly.sh backup
```

The backup contains credentials. Store it as securely as the live
configuration.

## Container health

Release v0.5.3 and newer reports liveness from the service supervisor every
five seconds. Scheduled `SendAll` work may take several minutes without making
the container unhealthy. The preview root and supervisor heartbeat are hard
health requirements; missing decorative artwork emits a repair warning and is
handled by `./tautweekly.sh repair-assets`.

Use `docker inspect` to read the exact failed probe, `./tautweekly.sh logs` for
service output, and `./tautweekly.sh schedule-status` for separate scheduler
progress. NAS, QNAP, and general Compose deployments share this behavior.

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
