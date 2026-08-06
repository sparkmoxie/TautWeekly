#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1;33m%s\033[0m\n' "$1"; }
ok() { printf '\033[0;32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2; exit 1; }

prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

confirm() {
  local prompt="$1" default="${2:-n}" answer suffix
  if [[ "$default" == "y" ]]; then suffix="Y/n"; else suffix="y/N"; fi
  read -r -p "$prompt [$suffix]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; return; fi
  fail "Docker Compose was not found. Install or update Docker Desktop for Mac."
}

detect_timezone() {
  local target=""
  if [[ -L /etc/localtime ]]; then
    target="$(readlink /etc/localtime 2>/dev/null || true)"
    if [[ "$target" == *"/zoneinfo/"* ]]; then
      printf '%s' "${target##*/zoneinfo/}"
      return
    fi
  fi
  printf '%s' "Etc/UTC"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer is specifically for macOS."
case "$(uname -m)" in
  arm64) ok "Apple silicon Mac detected" ;;
  x86_64) ok "Intel Mac detected" ;;
  *) fail "Unsupported Mac architecture: $(uname -m)" ;;
esac

command -v docker >/dev/null 2>&1 || fail "Docker Desktop is not installed or docker is not on PATH."
docker info >/dev/null 2>&1 || fail "Docker Desktop is not running. Open Docker Desktop and wait for the engine to start."
compose_cmd version >/dev/null
ok "Docker Desktop and Docker Compose are ready"

uid_value="$(id -u)"
gid_value="$(id -g)"
timezone_default="$(detect_timezone)"

if [[ -f .env ]]; then
  if confirm "An existing .env was found. Keep it?" y; then
    ok "Existing .env preserved"
  else
    cp .env ".env.backup.$(date +%Y%m%d-%H%M%S)"
    rm -f .env
  fi
fi

if [[ ! -f .env ]]; then
  say "Docker Desktop settings"
  timezone="$(prompt_default "IANA timezone" "$timezone_default")"
  preview_port="$(prompt_default "Local preview port" "8787")"
  cat > .env <<EOF
COMPOSE_PROJECT_NAME=tautweekly
TZ=$timezone
PUID=$uid_value
PGID=$gid_value
UMASK=077
PREVIEW_BIND=127.0.0.1
PREVIEW_PORT=$preview_port
PREVIEW_BASE_URL=http://localhost:$preview_port
EOF
  chmod 600 .env 2>/dev/null || true
  ok ".env created with macOS UID $uid_value and GID $gid_value"
fi

say "Building TautWeekly for Plex Mac Portable"
compose_cmd build --pull
compose_cmd up -d

for _ in $(seq 1 60); do
  if compose_cmd exec -T tautweekly true >/dev/null 2>&1; then break; fi
  sleep 2
done
compose_cmd exec -T tautweekly true >/dev/null 2>&1 || fail "The TautWeekly for Plex container did not become ready. Run docker compose logs tautweekly."
ok "TautWeekly for Plex container is running"

if [[ -f data/config.json ]]; then
  if confirm "A TautWeekly for Plex config already exists. Run setup again?" n; then
    compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1
  else
    ok "Existing data/config.json preserved"
  fi
else
  say "Interactive TautWeekly for Plex setup"
  compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1
fi

compose_cmd restart tautweekly >/dev/null
sleep 5

say "Verification"
if ! compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Verify-Setup.ps1; then
  fail "Verification failed. Correct the reported issue, then run ./tautweekly.sh verify."
fi

preview_url="$(awk -F= '$1=="PREVIEW_BASE_URL"{print substr($0,index($0,"=")+1)}' .env | tail -1)"
preview_url="${preview_url:-http://localhost:8787}"

cat <<EOF

TautWeekly for Plex Mac Portable is installed.

Next safe checks:
  ./tautweekly.sh list-users
  ./tautweekly.sh preview-all USER_ID
  ./tautweekly.sh send-test-all USER_ID
  ./tautweekly.sh schedule-status

Preview site:
  $preview_url/

Automatic sending remains disabled unless you enabled it during setup.
EOF
