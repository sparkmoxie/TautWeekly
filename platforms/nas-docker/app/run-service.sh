#!/usr/bin/env bash
set -euo pipefail
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
app_root="${TAUTWEEKLY_APP_DIR:-/opt/tautweekly}"
preview_bind="${TAUTWEEKLY_PREVIEW_BIND:-0.0.0.0}"
preview_port="${TAUTWEEKLY_PREVIEW_LISTEN_PORT:-8080}"
mkdir -p "$data_root/output" "$data_root/logs"
WEB_PID=""
SCHED_PID=""

term() {
  [[ -z "$SCHED_PID" ]] || kill -TERM "$SCHED_PID" 2>/dev/null || true
  [[ -z "$WEB_PID" ]] || kill -TERM "$WEB_PID" 2>/dev/null || true
}
trap term TERM INT EXIT

python3 -m http.server "$preview_port" --bind "$preview_bind" --directory "$data_root/output" \
  >>"$data_root/logs/preview-server.log" 2>&1 &
WEB_PID=$!

pwsh -NoLogo -NoProfile -NonInteractive -File "$app_root/Scheduler.ps1" -DataRoot "$data_root" &
SCHED_PID=$!

if wait "$SCHED_PID"; then
  STATUS=0
else
  STATUS=$?
fi

trap - EXIT
term
[[ -z "$WEB_PID" ]] || wait "$WEB_PID" 2>/dev/null || true
exit "$STATUS"
