#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-}"
shift || true
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
mkdir -p /data/logs /data/output /data/assets
exec 9>/data/.plexweekly-operation.lock
if ! flock -w 30 9; then
  echo "Another PlexWeekly operation is already running. Try again after it finishes." >&2
  exit 75
fi
ARGS=( -NoLogo -NoProfile -NonInteractive -File /opt/plexweekly/PlexWeekly.ps1 -Mode "$MODE" -ConfigPath /data/config.json )
if [[ -n "$USER_ID" ]]; then ARGS+=( -UserId "$USER_ID" ); fi
if [[ -n "$CONFIRM_SEND_ALL" ]]; then ARGS+=( "$CONFIRM_SEND_ALL" ); fi
if [[ -n "$CONFIRM_WELCOME" ]]; then ARGS+=( "$CONFIRM_WELCOME" ); fi
exec pwsh "${ARGS[@]}"
