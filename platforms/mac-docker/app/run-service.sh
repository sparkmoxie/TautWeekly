#!/usr/bin/env bash
set -euo pipefail
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
app_root="${TAUTWEEKLY_APP_DIR:-/opt/tautweekly}"
preview_bind="${TAUTWEEKLY_PREVIEW_BIND:-0.0.0.0}"
preview_port="${TAUTWEEKLY_PREVIEW_LISTEN_PORT:-8080}"
mkdir -p "$data_root/output" "$data_root/logs"
WEB_PID=""
SCHED_PID=""

if ! [[ "$preview_port" =~ ^[0-9]+$ ]] || (( preview_port < 1 || preview_port > 65535 )); then
  echo "[ERROR] TAUTWEEKLY_PREVIEW_LISTEN_PORT must be an integer from 1 through 65535." >&2
  exit 64
fi

term() {
  [[ -z "$SCHED_PID" ]] || kill -TERM "$SCHED_PID" 2>/dev/null || true
  [[ -z "$WEB_PID" ]] || kill -TERM "$WEB_PID" 2>/dev/null || true
}
trap term TERM INT EXIT

python3 -m http.server "$preview_port" --bind "$preview_bind" --directory "$data_root/output" \
  >>"$data_root/logs/preview-server.log" 2>&1 &
WEB_PID=$!

preview_ready=false
for _ in {1..50}; do
  if ! kill -0 "$WEB_PID" 2>/dev/null; then
    break
  fi
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${preview_port}/" >/dev/null; then
    preview_ready=true
    break
  fi
  sleep 0.2
done

if [[ "$preview_ready" != true ]]; then
  echo "[ERROR] Preview server failed to listen on ${preview_bind}:${preview_port}." >&2
  [[ ! -f "$data_root/logs/preview-server.log" ]] || tail -n 40 "$data_root/logs/preview-server.log" >&2
  exit 70
fi
echo "[INFO] Preview server listening on ${preview_bind}:${preview_port}; open the mapped host port for setup guidance and generated previews."

pwsh -NoLogo -NoProfile -NonInteractive -File "$app_root/Scheduler.ps1" -DataRoot "$data_root" &
SCHED_PID=$!

STATUS=0
while kill -0 "$WEB_PID" 2>/dev/null && kill -0 "$SCHED_PID" 2>/dev/null; do
  sleep 5
done

if ! kill -0 "$WEB_PID" 2>/dev/null; then
  if wait "$WEB_PID"; then STATUS=0; else STATUS=$?; fi
  (( STATUS != 0 )) || STATUS=70
  echo "[ERROR] Preview server exited unexpectedly with status $STATUS." >&2
  [[ ! -f "$data_root/logs/preview-server.log" ]] || tail -n 40 "$data_root/logs/preview-server.log" >&2
else
  if wait "$SCHED_PID"; then STATUS=0; else STATUS=$?; fi
  (( STATUS != 0 )) || STATUS=70
  echo "[ERROR] Scheduler exited unexpectedly with status $STATUS." >&2
fi

trap - EXIT
term
[[ -z "$WEB_PID" ]] || wait "$WEB_PID" 2>/dev/null || true
[[ -z "$SCHED_PID" ]] || wait "$SCHED_PID" 2>/dev/null || true
exit "$STATUS"
