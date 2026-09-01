#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; return; fi
  echo "Docker Compose was not found. Install/enable QNAP Container Station first." >&2
  exit 1
}

wait_for_container() {
  local attempts=60
  printf 'Waiting for the TautWeekly for Plex container to become ready'
  for ((i=1; i<=attempts; i++)); do
    if compose_cmd exec -T tautweekly true >/dev/null 2>&1; then
      printf ' ready.\n'
      return 0
    fi
    printf '.'
    sleep 2
  done
  printf '\nContainer did not become ready within 120 seconds.\n' >&2
  compose_cmd ps >&2 || true
  compose_cmd logs --tail=100 tautweekly >&2 || true
  return 1
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker was not found. Install and start QNAP Container Station first." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but the daemon is unavailable. Start Container Station and try again." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *)
    echo "Unsupported NAS CPU architecture: $(uname -m)" >&2
    echo "This edition supports 64-bit Intel/AMD and ARM64 Docker hosts." >&2
    exit 1
    ;;
esac

mkdir -p data
if [[ ! -f .env ]]; then
  PUID_VALUE="$(id -u)"
  PGID_VALUE="$(id -g)"
  if [[ "$PUID_VALUE" == "0" ]]; then
    PUID_VALUE="1000"
    echo "SSH session is root; using non-root container PUID=1000."
  fi
  if [[ "$PGID_VALUE" == "0" ]]; then
    PGID_VALUE="1000"
    echo "SSH session group is root; using non-root container PGID=1000."
  fi

  TZ_VALUE="Etc/UTC"
  if [[ -s /etc/timezone ]]; then TZ_VALUE="$(tr -d '\r\n' </etc/timezone)"; fi
  cat > .env <<EOF
COMPOSE_PROJECT_NAME=tautweekly
TZ=$TZ_VALUE
PUID=$PUID_VALUE
PGID=$PGID_VALUE
UMASK=077
PREVIEW_BIND=127.0.0.1
PREVIEW_PORT=8787
PREVIEW_BASE_URL=http://127.0.0.1:8787
MANAGER_ALLOWED_HOSTS=
MANAGER_SECURE_COOKIES=false
EOF
  chmod 600 .env 2>/dev/null || true
  echo "Created .env. Confirm TZ and PREVIEW_BASE_URL before production use."
else
  echo "Existing .env preserved."
fi

printf '\nPulling the current TautWeekly for Plex container image...\n'
./container-update.sh apply
wait_for_container

cat <<'EOF'

Installation is complete.

The authenticated Manager is available only through QNAP loopback. From the
administrator workstation, keep this local forward open while using Manager:

  ssh -N -L 8787:127.0.0.1:8787 ADMIN@QNAP_HOST

Retrieve the one-time pairing token explicitly in this administrator terminal;
the token is never printed to container logs:

  ./tautweekly.sh manager-bootstrap

Then open http://127.0.0.1:8787/, create the administrator password, and complete the
guided configuration, verification, preview, and TestEmail checks. Automatic
sending remains disabled until it is explicitly enabled in the Manager.
Optional public access uses only the independently verified Funnel URL; do not
add a broad bind, router port, firewall rule, or alternate proxy.
EOF
