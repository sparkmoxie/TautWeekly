#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-}"
shift || true
app_root="${TAUTWEEKLY_APP_DIR:-/opt/tautweekly}"
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
config_path="${TAUTWEEKLY_CONFIG:-$data_root/config.json}"
if [[ -z "$MODE" ]]; then
  echo "Usage: run-mode.sh MODE [user] [--confirm-send-all|--confirm-welcome]" >&2
  exit 64
fi
USER_ID=""
CONFIRM_SEND_ALL=""
CONFIRM_WELCOME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-send-all) CONFIRM_SEND_ALL="-ConfirmSendAll" ;;
    --confirm-welcome) CONFIRM_WELCOME="-ConfirmWelcome" ;;
    *)
      if [[ -z "$USER_ID" ]]; then USER_ID="$1"; else echo "Unexpected argument: $1" >&2; exit 64; fi
      ;;
  esac
  shift
done
mkdir -p "$data_root/logs" "$data_root/output" "$data_root/assets"
exec 9>"$data_root/.tautweekly-operation.lock"
if ! flock -w 30 9; then
  echo "Another TautWeekly for Plex operation is already running. Try again after it finishes." >&2
  exit 75
fi
ARGS=( -NoLogo -NoProfile -NonInteractive -File "$app_root/TautWeekly.ps1" -Mode "$MODE" -ConfigPath "$config_path" )
if [[ -n "$USER_ID" ]]; then ARGS+=( -UserId "$USER_ID" ); fi
if [[ -n "$CONFIRM_SEND_ALL" ]]; then ARGS+=( "$CONFIRM_SEND_ALL" ); fi
if [[ -n "$CONFIRM_WELCOME" ]]; then ARGS+=( "$CONFIRM_WELCOME" ); fi
exec pwsh "${ARGS[@]}"
