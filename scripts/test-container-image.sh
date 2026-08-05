#!/usr/bin/env bash
set -euo pipefail

image="${1:?Usage: test-container-image.sh IMAGE [BUILD_CONTEXT]}"
build_context="${2:-}"
container_name="tautweekly-smoke-$RANDOM-$$"
data_root="$(mktemp -d)"
container_started=false

cleanup() {
  if [[ "$container_started" == true ]]; then
    docker rm -f "$container_name" >/dev/null 2>&1 || true
  fi
  rm -rf "$data_root"
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

if [[ -n "$build_context" ]]; then
  docker build --tag "$image" "$build_context"
fi

host_uid="$(id -u)"
host_gid="$(id -g)"
if [[ "$host_uid" -eq 0 ]]; then host_uid=1000; fi
if [[ "$host_gid" -eq 0 ]]; then host_gid=1000; fi

docker run --detach \
  --name "$container_name" \
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

docker exec "$container_name" pwsh -NoLogo -NoProfile -NonInteractive -Command \
  'if ($PSVersionTable.PSVersion -lt [Version]"7.2") { exit 1 }' || fail 'PowerShell 7.2+ is unavailable in the runtime image.'
docker exec "$container_name" test -s /data/config.example.json || fail 'Persistent config example was not initialized.'
docker exec "$container_name" test -s /data/output/index.html || fail 'Preview landing page was not initialized.'
docker exec "$container_name" test -s /data/service-heartbeat.json || fail 'Service supervisor heartbeat was not initialized.'

set +e
root_output="$(docker run --rm -e PUID=0 -e PGID="$host_gid" "$image" 2>&1)"
root_status=$?
set -e
[[ "$root_status" -eq 64 ]] || fail "Root-identity rejection exited $root_status instead of 64."
grep -Fq 'PUID/PGID 0 is refused' <<<"$root_output" || fail 'Root-identity rejection was not actionable.'

printf '[PASS] Container boot, health, runtime, persistence, and root-refusal checks: %s\n' "$image"
