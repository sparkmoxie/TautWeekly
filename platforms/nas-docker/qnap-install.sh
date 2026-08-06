#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; return; fi
  echo "Docker Compose was not found. Install/enable QNAP Container Station first." >&2
  exit 1
}

detect_nas_ip() {
  local found=""
  if command -v hostname >/dev/null 2>&1; then
    found="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ && $0 !~ /^127\./ {print; exit}')"
  fi
  if [[ -z "$found" ]] && command -v ip >/dev/null 2>&1; then
    found="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  fi
  if [[ -z "$found" ]] && command -v ip >/dev/null 2>&1; then
    found="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {sub(/\/.*/,"",$2); print $2; exit}')"
  fi
  printf '%s' "${found:-nas.example.test}"
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
  NAS_IP="$(detect_nas_ip)"

  cat > .env <<EOF
COMPOSE_PROJECT_NAME=tautweekly
TZ=$TZ_VALUE
PUID=$PUID_VALUE
PGID=$PGID_VALUE
UMASK=077
PREVIEW_BIND=0.0.0.0
PREVIEW_PORT=8787
PREVIEW_BASE_URL=http://$NAS_IP:8787
EOF
  chmod 600 .env 2>/dev/null || true
  echo "Created .env. Confirm TZ and PREVIEW_BASE_URL before production use."
else
  echo "Existing .env preserved."
fi

printf '\nPulling the current TautWeekly for Plex container image...\n'
compose_cmd pull tautweekly
compose_cmd up -d
wait_for_container

printf '\nRunning the configuration wizard...\n'
compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1
compose_cmd restart tautweekly
wait_for_container

printf '\nRunning verification...\n'
if ! compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Verify-Setup.ps1; then
  echo "Verification failed. Review the messages above and run ./tautweekly.sh verify after correcting them." >&2
  exit 1
fi
cat <<'EOF'

Installation is complete.

Recommended acceptance sequence:
  ./tautweekly.sh verify
  ./tautweekly.sh list-users
  ./tautweekly.sh preview-all USER_ID
  ./tautweekly.sh send-test-all USER_ID
  ./tautweekly.sh schedule-status

Automatic sending remains disabled unless you explicitly enabled it in setup.
EOF
