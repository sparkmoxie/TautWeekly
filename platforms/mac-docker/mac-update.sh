#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

image_ref="tautweekly-mac:stable"
lock_marker="/data/.tautweekly-update-holder"
lock_container_id=""
package_backup=""
package_work_root=""
package_update_completed=false

print_metadata_readiness_note() {
  cat <<'EOF'
Open the authenticated Manager after the update, sign in, and confirm the
reported version, Manager/scheduler health, configuration status, all six
previews, and the explicit TestEmail result before relying on the next schedule.
If this update addresses missing ratings/artwork or results still appear stale,
complete metadata readiness before testing: confirm the Plex Movie Ratings
Source; run Plex Refresh All Metadata for each included movie/TV library; then
run Tautulli Library > Media Info > Refresh media info for each same library.
EOF
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; return; fi
  echo "Docker Compose was not found." >&2
  exit 69
}

package_version() {
  local value=""
  if [[ -r RELEASE-METADATA.txt ]]; then
    value="$(sed -n 's/^Repository version:[[:space:]]*v\{0,1\}\([0-9][0-9A-Za-z._-]*\)$/\1/p' RELEASE-METADATA.txt | head -n 1)"
  fi
  printf '%s' "${value:-dev}"
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

package_updater_path() {
  if [[ -f ./package-update.sh ]]; then printf '%s' ./package-update.sh; return; fi
  if [[ -f ../shared/package-update.sh ]]; then printf '%s' ../shared/package-update.sh; return; fi
  return 1
}

safe_remove_package_work_root() {
  [[ -n "$package_work_root" && -d "$package_work_root" ]] || return 0
  [[ "$(basename "$package_work_root")" == tautweekly-package-update.* ]] || {
    echo "Refusing to remove an unexpected package staging directory: $package_work_root" >&2
    return 1
  }
  rm -rf "$package_work_root"
}

update_exit_handler() {
  local status=$? updater
  release_operation_lock
  if [[ -n "$package_backup" && "$package_update_completed" != true ]]; then
    echo "Restoring the previous release-owned macOS package files..." >&2
    updater="$(package_updater_path || true)"
    if [[ -z "$updater" ]] || ! TAUTWEEKLY_PACKAGE_KIND=mac-docker TAUTWEEKLY_PACKAGE_ROOT="$(pwd -P)" \
        bash "$updater" restore-backup "$package_backup" "$(pwd -P)"; then
      echo "macOS package restoration needs administrator attention. Backup: $package_backup" >&2
    else
      echo "Previous macOS package files were restored; .env and data/ were unchanged." >&2
      safe_remove_package_work_root || true
    fi
  fi
  return "$status"
}

complete_package_update() {
  if [[ -n "$package_backup" ]]; then
    package_update_completed=true
    safe_remove_package_work_root
    package_backup=""
    package_work_root=""
    echo "macOS package and runtime update committed."
  fi
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
      if [[ "$state" == exited || "$state" == dead ]]; then break; fi
    fi
    sleep 2
  done
  compose_cmd ps >&2 || true
  compose_cmd logs --tail=100 tautweekly >&2 || true
  return 1
}

apply_package() {
  local version candidate candidate_id before before_version running_after after_version
  version="$(package_version)"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "A verified stable release package with semantic RELEASE-METADATA.txt is required." >&2
    exit 65
  fi
  candidate="tautweekly-mac:candidate-$version-$$"
  acquire_operation_lock
  before="$(running_image_id)"
  before_version="$(image_version "$before")"

  docker build --pull --build-arg "BUILD_VERSION=$version" --tag "$candidate" .
  candidate_id="$(docker image inspect --format '{{.Id}}' "$candidate")"
  docker image tag "$candidate" "$image_ref"

  compose_args=(up -d --no-build)
  [[ -z "$package_backup" ]] || compose_args+=(--force-recreate)
  compose_args+=(tautweekly)
  if compose_cmd "${compose_args[@]}" && wait_for_health; then
    running_after="$(running_image_id)"
    after_version="$(image_version "$running_after")"
    if [[ "$running_after" == "$candidate_id" && "$after_version" == "$version" ]]; then
      echo "Applied macOS package version $version; .env and data were preserved."
      print_metadata_readiness_note
      complete_package_update
      return
    fi
    echo "The running image reports $after_version ($running_after), expected $version ($candidate_id)." >&2
  fi

  echo "The rebuilt container failed version or health verification." >&2
  if [[ -z "$before" ]]; then
    echo "No previous running image was available for automatic rollback." >&2
    exit 70
  fi
  docker image tag "$before" "$image_ref"
  compose_cmd up -d --no-build --force-recreate tautweekly
  if wait_for_health && [[ "$(running_image_id)" == "$before" ]]; then
    echo "Rollback to macOS image version $before_version succeeded." >&2
  else
    echo "Rollback also failed health verification. Previous image ID: $before" >&2
  fi
  exit 70
}

mode="${1:-apply}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-backup) package_backup="${2:-}"; shift 2 ;;
    --package-work-root) package_work_root="${2:-}"; shift 2 ;;
    *) echo "Unknown update option: $1" >&2; exit 64 ;;
  esac
done
if [[ -n "$package_backup" && -z "$package_work_root" ]] || [[ -z "$package_backup" && -n "$package_work_root" ]]; then
  echo "Package backup and staging roots must be supplied together." >&2
  exit 64
fi

case "$mode" in
  apply) trap update_exit_handler EXIT; apply_package ;;
  check) exec ./check-release.sh "${1:-./RELEASE-METADATA.txt}" ;;
  *) echo "Usage: ./mac-update.sh check|apply" >&2; exit 64 ;;
esac
