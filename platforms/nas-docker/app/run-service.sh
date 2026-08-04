#!/usr/bin/env bash
set -euo pipefail
mkdir -p /data/output /data/logs
WEB_PID=""
SCHED_PID=""

term() {
  [[ -z "$SCHED_PID" ]] || kill -TERM "$SCHED_PID" 2>/dev/null || true
  [[ -z "$WEB_PID" ]] || kill -TERM "$WEB_PID" 2>/dev/null || true
}
trap term TERM INT EXIT

python3 -m http.server 8080 --bind 0.0.0.0 --directory /data/output \
  >>/data/logs/preview-server.log 2>&1 &
WEB_PID=$!

pwsh -NoLogo -NoProfile -NonInteractive -File /opt/plexweekly/Scheduler.ps1 &
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
