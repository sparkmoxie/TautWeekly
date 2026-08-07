#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

image_ref="${TAUTWEEKLY_IMAGE:-ghcr.io/sparkmoxie/tautweekly:latest}"
lock_marker="/data/.tautweekly-update-holder"
lock_container_id=""

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; return; fi
  echo "Docker Compose was not found." >&2
  exit 69
}

container_id() {
  compose_cmd ps -q tautweekly 2>/dev/null | head -n 1
}

running_image_id() {
  local id
  id="$(container_id)"
  [[ -n "$id" ]] || return 0
  docker inspect --format '{{.Image}}' "$id" 2>/dev/null || true
}

image_id() {
  docker image inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true
}

image_version() {
  local target="$1" version=""
  [[ -n "$target" ]] || { printf '%s' unknown; return; }
  version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$target" 2>/dev/null || true)"
  printf '%s' "${version:-unknown}"
}

release_operation_lock() {
  local current_id
  current_id="$(container_id)"
  if [[ -n "$lock_container_id" && "$current_id" == "$lock_container_id" ]]; then
    compose_cmd exec -T tautweekly sh -c \
      'if [ -s /data/.tautweekly-update-holder ]; then kill "$(cat /data/.tautweekly-update-holder)" 2>/dev/null || true; fi; rm -f /data/.tautweekly-update-holder' \
      >/dev/null 2>&1 || true
  else
    compose_cmd exec -T tautweekly rm -f "$lock_marker" >/dev/null 2>&1 || true
  fi
  lock_container_id=""
}

acquire_operation_lock() {
  local id
  id="$(container_id)"
  [[ -n "$id" ]] || return 0
  lock_container_id="$id"
  compose_cmd exec -T tautweekly rm -f "$lock_marker" >/dev/null 2>&1 || true
  compose_cmd exec -T -d tautweekly flock -n /data/.tautweekly-operation.lock sh -c \
    'echo $$ > /data/.tautweekly-update-holder; trap "rm -f /data/.tautweekly-update-holder" EXIT HUP INT TERM; while :; do sleep 60; done'
  for _ in $(seq 1 20); do
    if compose_cmd exec -T tautweekly test -s "$lock_marker" >/dev/null 2>&1; then
      trap release_operation_lock EXIT
      return 0
    fi
    sleep 1
  done
  release_operation_lock
  echo "Another TautWeekly operation is running; the update was not started." >&2
  exit 75
}

wait_for_health() {
  local id state health
  for _ in $(seq 1 60); do
    id="$(container_id)"
    if [[ -n "$id" ]]; then
      state="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)"
      if [[ "$state" == running && "$health" == healthy ]]; then return 0; fi
      if [[ "$state" == running && "$health" == none ]] && \
          compose_cmd exec -T tautweekly /opt/tautweekly/healthcheck.sh >/dev/null 2>&1; then
        return 0
      fi
      if [[ "$state" == exited || "$state" == dead ]]; then break; fi
    fi
    sleep 2
  done
  compose_cmd ps >&2 || true
  compose_cmd logs --tail=100 tautweekly >&2 || true
  return 1
}

check_update() {
  local before after before_version after_version
  image_ref="$(compose_cmd config --images | head -n 1)"
  [[ -n "$image_ref" ]] || { echo "The configured Compose image could not be resolved." >&2; exit 69; }
  before="$(running_image_id)"
  before_version="$(image_version "$before")"
  compose_cmd pull tautweekly
  after="$(image_id)"
  [[ -n "$after" ]] || { echo "The configured image could not be inspected after pull: $image_ref" >&2; exit 69; }
  after_version="$(image_version "$after")"
  [[ "$after_version" != unknown ]] || { echo "The staged image has no repository version label; refusing to treat it as a release update." >&2; exit 65; }

  echo "Running image version: $before_version"
  echo "Latest configured image version: $after_version"
  if [[ -z "$before" ]]; then
    echo "The stable image is staged, but no TautWeekly container is running."
  elif [[ "$before" == "$after" ]]; then
    echo "The running container is up to date."
  else
    echo "An update is staged. Run ./tautweekly.sh update to recreate the service."
  fi
}

apply_update() {
  local before after before_version after_version running_after running_after_version restored
  image_ref="$(compose_cmd config --images | head -n 1)"
  [[ -n "$image_ref" ]] || { echo "The configured Compose image could not be resolved." >&2; exit 69; }
  acquire_operation_lock
  before="$(running_image_id)"
  before_version="$(image_version "$before")"
  compose_cmd pull tautweekly
  after="$(image_id)"
  [[ -n "$after" ]] || { echo "The configured image could not be inspected after pull: $image_ref" >&2; exit 69; }
  after_version="$(image_version "$after")"
  [[ "$after_version" != unknown ]] || { echo "The staged image has no repository version label; refusing to apply it." >&2; exit 65; }

  if [[ -n "$before" && "$before" == "$after" ]]; then
    wait_for_health
    echo "The running container is already on stable image version $after_version."
    return
  fi

  if compose_cmd up -d --no-build tautweekly && wait_for_health; then
    running_after="$(running_image_id)"
    running_after_version="$(image_version "$running_after")"
    if [[ "$running_after" == "$after" && "$running_after_version" == "$after_version" ]]; then
      echo "Updated TautWeekly from $before_version to $running_after_version; persistent data was not replaced."
      return
    fi
    echo "The recreated service reports image $running_after_version ($running_after), expected $after_version ($after)." >&2
  fi

  echo "The updated container failed its health check." >&2
  if [[ -z "$before" ]]; then
    echo "No previous running image was available for automatic rollback." >&2
    exit 70
  fi

  echo "Restoring the previous image $before_version..." >&2
  docker image tag "$before" "$image_ref"
  compose_cmd up -d --no-build --force-recreate tautweekly
  restored=false
  if wait_for_health && [[ "$(running_image_id)" == "$before" ]]; then restored=true; fi
  if [[ "$restored" == true ]]; then
    echo "Rollback succeeded; the previous image is healthy. Review logs before retrying." >&2
  else
    echo "Rollback also failed health verification. Restore from the recorded image ID: $before" >&2
  fi
  exit 70
}

case "${1:-check}" in
  check) check_update ;;
  apply) apply_update ;;
  *) echo "Usage: ./container-update.sh check|apply" >&2; exit 64 ;;
esac
