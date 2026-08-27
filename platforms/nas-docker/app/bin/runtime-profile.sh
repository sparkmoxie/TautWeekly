#!/usr/bin/env bash

# Resolve the host-facing container profile before any Manager or scheduler
# process starts. Keep package identity separate from runtime behavior so a new
# compatible host can reuse a profile without forking the application payload.
tautweekly_select_runtime_profile() {
  local profile="${TAUTWEEKLY_RUNTIME_PROFILE:-}"
  local package_kind="${TAUTWEEKLY_PACKAGE_KIND:-}"

  if [[ -z "$profile" ]]; then
    case "$package_kind" in
      unraid) profile="unraid" ;;
      mac-docker|mac-docker-registry|container-desktop) profile="desktop" ;;
      *) profile="server" ;;
    esac
  fi

  case "$profile" in
    desktop)
      case "$package_kind" in
        "") package_kind="container-desktop" ;;
        container-desktop|mac-docker|mac-docker-registry) ;;
        *)
          echo "[ERROR] Runtime profile desktop is incompatible with package kind '$package_kind'." >&2
          return 64
          ;;
      esac
      TAUTWEEKLY_MANAGER_RUNTIME_MODE="mac"
      ;;
    server)
      case "$package_kind" in
        "") package_kind="docker-compatible" ;;
        container-compose|docker-compatible|nas-docker|qnap-container-station|freebsd-podman) ;;
        *)
          echo "[ERROR] Runtime profile server is incompatible with package kind '$package_kind'." >&2
          return 64
          ;;
      esac
      TAUTWEEKLY_MANAGER_RUNTIME_MODE="nas"
      ;;
    unraid)
      if [[ -z "$package_kind" ]]; then
        package_kind="unraid"
      elif [[ "$package_kind" != "unraid" ]]; then
        echo "[ERROR] Runtime profile unraid requires package kind 'unraid', not '$package_kind'." >&2
        return 64
      fi
      TAUTWEEKLY_MANAGER_RUNTIME_MODE="nas"
      ;;
    *)
      echo "[ERROR] TAUTWEEKLY_RUNTIME_PROFILE must be desktop, server, or unraid." >&2
      return 64
      ;;
  esac

  TAUTWEEKLY_RUNTIME_PROFILE="$profile"
  TAUTWEEKLY_PACKAGE_KIND="$package_kind"
  export TAUTWEEKLY_RUNTIME_PROFILE TAUTWEEKLY_PACKAGE_KIND TAUTWEEKLY_MANAGER_RUNTIME_MODE
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  tautweekly_select_runtime_profile || exit $?
  printf 'profile=%s\npackage=%s\nmanager=%s\n' \
    "$TAUTWEEKLY_RUNTIME_PROFILE" "$TAUTWEEKLY_PACKAGE_KIND" "$TAUTWEEKLY_MANAGER_RUNTIME_MODE"
fi
