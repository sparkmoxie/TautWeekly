#!/usr/bin/env bash
set -euo pipefail

image="${1:?Usage: test-container-image.sh IMAGE [BUILD_CONTEXT] [RUNTIME_PROFILE]}"
build_context="${2:-}"
runtime_profile="${3:-nas}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container_name="tautweekly-smoke-$RANDOM-$$"
data_root="$(mktemp -d)"
generated_context=""
container_started=false

cleanup() {
  if [[ "$container_started" == true ]]; then
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  rm -rf "$data_root"
  if [[ -n "$generated_context" ]]; then
    rm -rf "$generated_context"
  fi
}
trap cleanup EXIT

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  if [[ "$container_started" == true ]]; then
    docker inspect "$container_name" >&2 || true
    docker logs "$container_name" >&2 || true
  fi
  exit 1
}

case "$runtime_profile" in
  nas|mac) ;;
  *) fail "Unsupported runtime profile: $runtime_profile" ;;
esac

if [[ -n "$build_context" ]]; then
  if [[ "$runtime_profile" == mac && ! -d "$build_context/manager" ]]; then
    command -v go >/dev/null 2>&1 || fail 'Go is required to stage the Mac Manager build context.'
    case "$(uname -m)" in
      x86_64|amd64) manager_arch=amd64 ;;
      aarch64|arm64) manager_arch=arm64 ;;
      *) fail 'Mac image smoke staging requires a supported 64-bit host architecture.' ;;
    esac
    generated_context="$(mktemp -d)"
    cp -a "$build_context/." "$generated_context/"
    mkdir -p "$generated_context/manager"
    (
      cd "$repo_root/manager"
      CGO_ENABLED=0 GOOS=linux GOARCH="$manager_arch" go build -trimpath -buildvcs=false -ldflags '-s -w -X main.version=ci' -o "$generated_context/manager/tautweekly-manager-linux-$manager_arch" ./cmd/tautweekly-manager
    )
    build_context="$generated_context"
  fi
  docker build --tag "$image" "$build_context"
fi

host_uid="$(id -u)"
host_gid="$(id -g)"
if [[ "$host_uid" -eq 0 ]]; then host_uid=1000; fi
if [[ "$host_gid" -eq 0 ]]; then host_gid=1000; fi

security_args=(
  --read-only
  --tmpfs '/tmp:rw,noexec,nosuid,size=256m,mode=1777'
  --security-opt no-new-privileges:true
  --cap-drop ALL
  --cap-add CHOWN
  --cap-add DAC_OVERRIDE
  --cap-add FOWNER
  --cap-add SETGID
  --cap-add SETUID
)

docker run --detach \
  --name "$container_name" \
  "${security_args[@]}" \
  -e "PUID=$host_uid" \
  -e "PGID=$host_gid" \
  -e 'UMASK=077' \
  -e 'TZ=Etc/UTC' \
  -v "$data_root:/data" \
  "$image" >/dev/null
container_started=true

healthy=false
for _ in {1..100}; do
  running="$(docker inspect --format '{{.State.Running}}' "$container_name")"
  [[ "$running" == true ]] || fail 'Container exited during startup.'
  if docker exec "$container_name" /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 0.2
done
[[ "$healthy" == true ]] || fail 'Container never passed its production healthcheck.'

docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh pwsh -NoLogo -NoProfile -NonInteractive -Command \
  'if ($PSVersionTable.PSVersion -lt [Version]"7.2") { exit 1 }' || fail 'PowerShell 7.2+ is unavailable in the runtime image.'
docker exec "$container_name" test -s /data/config.example.json || fail 'Persistent config example was not initialized.'
if [[ "$runtime_profile" == mac ]]; then
  docker exec "$container_name" test -s /data/output/index.html || fail 'Preview landing page was not initialized.'
fi
docker exec "$container_name" test -s /data/output/product-branding/favicon.ico || fail 'Preview favicon was not initialized.'
docker exec "$container_name" test -s /data/output/product-branding/tautweekly-app-icon-128.png || fail 'Preview product icon was not initialized.'
docker exec "$container_name" test -s /data/service-heartbeat.json || fail 'Service supervisor heartbeat was not initialized.'
if [[ "$runtime_profile" == nas || "$runtime_profile" == mac ]]; then
  docker exec "$container_name" test -x /opt/tautweekly/bin/tautweekly-manager || fail "$runtime_profile Manager binary is unavailable."
  setup_json="$(docker exec "$container_name" curl -fsS http://127.0.0.1:8080/api/v1/setup)"
  grep -Fq '"authenticationRequired":true' <<<"$setup_json" || fail "$runtime_profile Manager authentication is not mandatory."
  grep -Fq "\"runtimeMode\":\"$runtime_profile\"" <<<"$setup_json" || fail "$runtime_profile Manager did not report its container runtime profile."
  bootstrap_token="$(docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager)"
  [[ "$bootstrap_token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || fail 'Explicit bootstrap command did not return a one-time token.'
  if docker logs "$container_name" 2>&1 | grep -Fq "$bootstrap_token"; then
    fail 'The one-time Manager bootstrap token was exposed in container logs.'
  fi
fi

# A normal docker exec bypasses entrypoint.sh and therefore begins as root.
# run-mode.sh must still drop to PUID/PGID before it creates any data.
[[ "$(docker exec "$container_name" id -u)" == "0" ]] || fail 'Ownership regression precondition did not start docker exec as root.'

# Older direct helper invocations could leave root-owned configuration or logs
# in /data. The shared privilege launcher must repair those entries without
# following a symlink outside the dedicated data filesystem.
docker exec "$container_name" sh -c 'mkdir -p /data/logs /tmp/tautweekly-ownership-target && touch /data/logs/legacy-root.log /tmp/tautweekly-ownership-target/private && ln -sfn /tmp/tautweekly-ownership-target/private /data/legacy-root-link'
[[ "$(docker exec "$container_name" stat -c '%u:%g' /data/logs/legacy-root.log)" == '0:0' ]] || fail 'Legacy ownership regression precondition was not root-owned.'
[[ "$(docker exec "$container_name" /opt/tautweekly/bin/run-as-user.sh id -u)" == "$host_uid" ]] || fail 'Shared exec launcher did not drop to the configured UID.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' /data/logs/legacy-root.log)" == "$host_uid:$host_gid" ]] || fail 'Shared exec launcher did not repair a legacy root-owned log.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' /tmp/tautweekly-ownership-target/private)" == '0:0' ]] || fail 'Shared exec launcher followed a symlink outside /data.'

ownership_probe='/data/exec-ownership-probe'
docker exec "$container_name" rm -rf "$ownership_probe"
docker exec \
  -e "TAUTWEEKLY_DATA_DIR=$ownership_probe" \
  -e "TAUTWEEKLY_CONFIG=$ownership_probe/missing-config.json" \
  "$container_name" /opt/tautweekly/bin/run-mode.sh InvalidOwnershipProbe \
  >/dev/null 2>&1 || true
docker exec "$container_name" test -f "$ownership_probe/.tautweekly-operation.lock" || fail 'Root-started run-mode did not create the ownership probe lock.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' "$ownership_probe")" == "$host_uid:$host_gid" ]] || fail 'Root-started run-mode created its data directory with the wrong owner.'
[[ "$(docker exec "$container_name" stat -c '%u:%g' "$ownership_probe/.tautweekly-operation.lock")" == "$host_uid:$host_gid" ]] || fail 'Root-started run-mode created its operation lock with the wrong owner.'

set +e
root_output="$(docker run --rm -e PUID=0 -e PGID="$host_gid" "$image" 2>&1)"
root_status=$?
set -e
[[ "$root_status" -eq 64 ]] || fail "Root-identity rejection exited $root_status instead of 64."
grep -Fq 'PUID/PGID 0 is refused' <<<"$root_output" || fail 'Root-identity rejection was not actionable.'

printf '[PASS] Container boot, health, runtime, persistence, and root-refusal checks (%s): %s\n' "$runtime_profile" "$image"
