#!/usr/bin/env bash
set -euo pipefail
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
app_root="${TAUTWEEKLY_APP_DIR:-/opt/tautweekly}"
manager_listen="${TAUTWEEKLY_MANAGER_LISTEN:-0.0.0.0:8080}"
service_heartbeat="$data_root/service-heartbeat.json"
shutdown_grace="${TAUTWEEKLY_SHUTDOWN_DELIVERY_GRACE_SECONDS:-1740}"
mkdir -p "$data_root/output" "$data_root/logs" "$data_root/manager"
MANAGER_PID=""
SCHED_PID=""
SHUTTING_DOWN=false

if ! [[ "$manager_listen" =~ ^[^:]+:[0-9]+$ ]]; then
  echo "[ERROR] TAUTWEEKLY_MANAGER_LISTEN must be an address and port, for example 0.0.0.0:8080." >&2
  exit 64
fi
manager_port="${manager_listen##*:}"
if (( manager_port < 1 || manager_port > 65535 )); then
  echo "[ERROR] TAUTWEEKLY_MANAGER_LISTEN port must be from 1 through 65535." >&2
  exit 64
fi
if ! [[ "$shutdown_grace" =~ ^[0-9]+$ ]] || (( shutdown_grace < 0 || shutdown_grace > 86400 )); then
  echo "[ERROR] TAUTWEEKLY_SHUTDOWN_DELIVERY_GRACE_SECONDS must be from 0 through 86400." >&2
  exit 64
fi

write_service_heartbeat() {
  local temp_path="${service_heartbeat}.tmp"
  local utc_now
  utc_now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"Utc":"%s","ProcessId":%s,"ManagerProcessId":%s,"SchedulerProcessId":%s}\n' \
    "$utc_now" "$$" "${MANAGER_PID:-0}" "${SCHED_PID:-0}" >"$temp_path"
  mv -f "$temp_path" "$service_heartbeat"
}

operation_is_active() {
  exec 8>"$data_root/.tautweekly-operation.lock"
  if flock -n 8; then
    flock -u 8
    exec 8>&-
    return 1
  fi
  exec 8>&-
  return 0
}

wait_for_delivery() {
  local waited=0
  while operation_is_active && (( waited < shutdown_grace )); do
    if (( waited == 0 )); then
      echo "[INFO] Docker Desktop shutdown is waiting for the active newsletter operation to finish."
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if operation_is_active; then
    echo "[WARN] Active newsletter operation exceeded the ${shutdown_grace}-second graceful shutdown window." >&2
    return 1
  fi
  if (( waited > 0 )); then
    echo "[INFO] Active newsletter operation finished after ${waited} second(s); Docker Desktop shutdown may continue."
  fi
  return 0
}

term() {
  [[ "$SHUTTING_DOWN" == false ]] || return 0
  SHUTTING_DOWN=true
  [[ -z "$MANAGER_PID" ]] || kill -TERM "$MANAGER_PID" 2>/dev/null || true
  [[ -z "$MANAGER_PID" ]] || wait "$MANAGER_PID" 2>/dev/null || true
  wait_for_delivery || true
  [[ -z "$SCHED_PID" ]] || kill -TERM "$SCHED_PID" 2>/dev/null || true
}
trap term TERM INT EXIT

"$app_root/bin/tautweekly-manager" serve \
  --runtime-mode mac \
  --listen "$manager_listen" \
  --tautweekly-root "$app_root" \
  --runtime-root "$data_root" \
  --data-dir "$data_root/manager" \
  >>"$data_root/logs/manager.log" 2>&1 &
MANAGER_PID=$!

manager_ready=false
for _ in {1..50}; do
  if ! kill -0 "$MANAGER_PID" 2>/dev/null; then
    break
  fi
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${manager_port}/health/live" >/dev/null; then
    manager_ready=true
    break
  fi
  sleep 0.2
done

if [[ "$manager_ready" != true ]]; then
  echo "[ERROR] macOS Manager failed to listen on ${manager_listen}." >&2
  [[ ! -f "$data_root/logs/manager.log" ]] || tail -n 40 "$data_root/logs/manager.log" >&2
  exit 70
fi
echo "[INFO] Authenticated macOS Docker Desktop Manager listening on ${manager_listen}; the host package publishes it to Mac loopback by default."

pwsh -NoLogo -NoProfile -NonInteractive -File "$app_root/Scheduler.ps1" -DataRoot "$data_root" &
SCHED_PID=$!

STATUS=0
write_service_heartbeat
while kill -0 "$MANAGER_PID" 2>/dev/null && kill -0 "$SCHED_PID" 2>/dev/null; do
  write_service_heartbeat
  sleep 5
done

if [[ "$SHUTTING_DOWN" == true ]]; then
  STATUS=0
elif ! kill -0 "$MANAGER_PID" 2>/dev/null; then
  if wait "$MANAGER_PID"; then STATUS=0; else STATUS=$?; fi
  (( STATUS != 0 )) || STATUS=70
  echo "[ERROR] macOS Manager exited unexpectedly with status $STATUS." >&2
  [[ ! -f "$data_root/logs/manager.log" ]] || tail -n 40 "$data_root/logs/manager.log" >&2
else
  if wait "$SCHED_PID"; then STATUS=0; else STATUS=$?; fi
  (( STATUS != 0 )) || STATUS=70
  echo "[ERROR] Scheduler exited unexpectedly with status $STATUS." >&2
fi

term
trap - EXIT
[[ -z "$MANAGER_PID" ]] || wait "$MANAGER_PID" 2>/dev/null || true
[[ -z "$SCHED_PID" ]] || wait "$SCHED_PID" 2>/dev/null || true
exit "$STATUS"
