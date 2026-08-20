#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
shift || true
script_dir="$(cd "$(dirname "$0")" && pwd)"
app_root="${TAUTWEEKLY_APP_DIR:-/opt/tautweekly}"
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
config_path="${TAUTWEEKLY_CONFIG:-$data_root/config.json}"
if [[ "$(id -u)" -eq 0 ]]; then
  exec "$script_dir/run-as-user.sh" "$0" "$MODE" "$@"
fi
if [[ -z "$MODE" ]]; then
  echo "Usage: run-mode.sh MODE [user] [--confirm-send-all|--confirm-welcome]" >&2
  exit 64
fi
USER_ID=""
CONFIRM_SEND_ALL=""
CONFIRM_WELCOME=""
NO_OPEN=""
MANAGER_CONFIG=""
MANAGER_RESULT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-send-all) CONFIRM_SEND_ALL="-ConfirmSendAll" ;;
    --confirm-welcome) CONFIRM_WELCOME="-ConfirmWelcome" ;;
    --no-open) NO_OPEN="-NoOpen" ;;
    --manager-config)
      [[ $# -ge 2 ]] || { echo "--manager-config requires a path." >&2; exit 64; }
      MANAGER_CONFIG="$2"
      shift
      ;;
    --manager-result)
      [[ $# -ge 2 ]] || { echo "--manager-result requires a path." >&2; exit 64; }
      MANAGER_RESULT="$2"
      shift
      ;;
    *)
      if [[ -z "$USER_ID" ]]; then USER_ID="$1"; else echo "Unexpected argument: $1" >&2; exit 64; fi
      ;;
  esac
  shift
done
mkdir -p "$data_root/logs" "$data_root/output" "$data_root/assets"

if [[ -n "$MANAGER_CONFIG" || -n "$MANAGER_RESULT" ]]; then
  manager_root="$data_root/manager"
  manager_config_name="${MANAGER_CONFIG#"$manager_root"/}"
  manager_result_name="${MANAGER_RESULT#"$manager_root"/}"
  manager_config_id=""
  manager_result_id=""
  if [[ "$MANAGER_CONFIG" == "$manager_root"/* &&
        "$manager_config_name" =~ ^operation-([A-Za-z0-9_-]{16})\.config\.json$ ]]; then
    manager_config_id="${BASH_REMATCH[1]}"
  fi
  if [[ "$MANAGER_RESULT" == "$manager_root"/* &&
        "$manager_result_name" =~ ^operation-([A-Za-z0-9_-]{16})\.result\.json$ ]]; then
    manager_result_id="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$manager_config_id" || "$manager_config_id" != "$manager_result_id" ||
        ! -f "$MANAGER_CONFIG" || -L "$MANAGER_CONFIG" ||
        -e "$MANAGER_RESULT" || -L "$MANAGER_RESULT" ||
        ! -d "$manager_root" || -L "$manager_root" ]]; then
    echo "Manager operation paths are invalid." >&2
    exit 64
  fi
  config_path="$MANAGER_CONFIG"
elif [[ -n "$NO_OPEN" ]]; then
  echo "--no-open is reserved for Manager operations." >&2
  exit 64
fi

exec 9>"$data_root/.tautweekly-operation.lock"
if [[ -n "$MANAGER_RESULT" ]]; then
  lock_args=( -n 9 )
else
  lock_args=( -w 30 9 )
fi
if ! flock "${lock_args[@]}"; then
  echo "Another TautWeekly for Plex operation is already running. Try again after it finishes." >&2
  exit 75
fi
ARGS=( -NoLogo -NoProfile -NonInteractive -File "$app_root/TautWeekly.ps1" -Mode "$MODE" -ConfigPath "$config_path" )
if [[ -n "$USER_ID" ]]; then ARGS+=( -UserId "$USER_ID" ); fi
if [[ -n "$MANAGER_RESULT" ]]; then ARGS+=( -ResultPath "$MANAGER_RESULT" ); fi
if [[ -z "$MANAGER_RESULT" && "$MODE" == "SendAll" ]]; then ARGS+=( -ResultPath "$data_root/last-run.json" ); fi
if [[ -n "$NO_OPEN" ]]; then ARGS+=( "$NO_OPEN" ); fi
if [[ -n "$CONFIRM_SEND_ALL" ]]; then ARGS+=( "$CONFIRM_SEND_ALL" ); fi
if [[ -n "$CONFIRM_WELCOME" ]]; then ARGS+=( "$CONFIRM_WELCOME" ); fi
exec pwsh "${ARGS[@]}"
