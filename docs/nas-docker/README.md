# NAS / Docker Compose installation

[Open the rendered interactive NAS walkthrough](https://sparkmoxie.github.io/TautWeekly/nas-docker/)
· [Open the rendered Compose quick start](https://sparkmoxie.github.io/TautWeekly/nas-docker/quickstart.html)

This distribution runs TautWeekly for Plex as a dedicated Docker Compose service beside
Tautulli. It targets QNAP Container Station, Unraid, and general Linux Docker
hosts on x86-64 or ARM64.

Current source baseline: **1.0.7**.

## Requirements

- Docker Engine and Docker Compose v2, or a compatible vendor Compose UI.
- A non-root UID and GID that can write the project `data/` directory.
- Network access from the container to Tautulli and an SMTP STARTTLS endpoint.
- A Tautulli API key.
- A trusted host port for the local preview service; default 8787.

## Install from a release

Download the latest
[`TautWeekly-nas-docker.tar.gz`](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.tar.gz)
or [ZIP archive](https://github.com/sparkmoxie/TautWeekly/releases/latest/download/TautWeekly-nas-docker.zip),
then extract one format:

```bash
tar -xzf TautWeekly-nas-docker.tar.gz
cd TautWeekly-nas-docker
chmod +x qnap-install.sh tautweekly.sh app/*.sh app/bin/*.sh
```

For QNAP, run the guided installer:

```bash
./qnap-install.sh
```

For Unraid or a general Docker host, use the portable Compose workflow:

```bash
cp .env.example .env
# Edit .env: timezone, UID/GID, preview bind, and preview URL.
docker compose build --pull
docker compose up -d
./tautweekly.sh setup
./tautweekly.sh verify
```

Use a hostname reachable from inside the container, for example
`http://media.example.test:8181`. Do not use `127.0.0.1` for Tautulli unless it
runs in the same container, which is not the supported deployment model.

## Safe acceptance sequence

```bash
./tautweekly.sh verify
./tautweekly.sh list-users
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
