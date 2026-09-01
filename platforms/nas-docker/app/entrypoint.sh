#!/usr/bin/env bash
set -euo pipefail
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
UMASK_VALUE="${UMASK:-077}"
HOST_ADAPTER_API="${TAUTWEEKLY_HOST_ADAPTER_API:-legacy}"
FUNNEL_ADAPTER="${TAUTWEEKLY_FUNNEL_ADAPTER:-disabled}"
umask "$UMASK_VALUE"

# shellcheck source=bin/runtime-profile.sh
source /opt/tautweekly/bin/runtime-profile.sh
tautweekly_select_runtime_profile
echo "[INFO] Unified container profile '$TAUTWEEKLY_RUNTIME_PROFILE' selected for package '$TAUTWEEKLY_PACKAGE_KIND'."

if [[ "$HOST_ADAPTER_API" != 4 ]]; then
  echo "[WARN] Host adapter API ${HOST_ADAPTER_API} is older than image API 4. The Manager can start, but Settings > Updates will report the legacy adapter until the host package or saved container template is current." >&2
fi

if [[ "$FUNNEL_ADAPTER" != disabled && "$FUNNEL_ADAPTER" != enabled ]]; then
  echo "TAUTWEEKLY_FUNNEL_ADAPTER must be exactly disabled or enabled." >&2
  exit 64
fi

if ! [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]]; then
  echo "PUID and PGID must be numeric." >&2
  exit 64
fi
if [[ "$PUID" == "0" || "$PGID" == "0" ]]; then
  echo "PUID/PGID 0 is refused. Configure a non-root numeric identity, normally 1000:1000." >&2
  exit 64
fi

mkdir -p /tmp/tautweekly/home /tmp/tautweekly/config /tmp/tautweekly/cache /tmp/tautweekly/share /tmp/tautweekly/dotnet
chown -R "$PUID:$PGID" /tmp/tautweekly
# Refresh shipped filenames only when the bundled content changes (or no marker
# exists), before any Manager/scheduler process can use persistent artwork.
python3 /opt/tautweekly/refresh-assets.py --data-root /data
mkdir -p /data/logs /data/manager /data/output/posters /data/output/media
mkdir -p /data/output/product-branding
cp -af /opt/tautweekly/product-branding/. /data/output/product-branding/
if [[ ! -f /data/config.example.json ]]; then
  cp /opt/tautweekly/config.example.json /data/config.example.json
fi
chown -R "$PUID:$PGID" /data
chmod 700 /data 2>/dev/null || true
[[ ! -f /data/config.json ]] || chmod 600 /data/config.json 2>/dev/null || true

adapter_pid=""
service_pid=""
shutting_down=false
termination_requested=false

stop_service() {
  [[ "$shutting_down" == false ]] || return 0
  shutting_down=true
  if [[ -n "$service_pid" ]] && kill -0 "$service_pid" 2>/dev/null; then
    if ! kill -TERM "$service_pid" 2>/dev/null; then
      if kill -0 "$service_pid" 2>/dev/null; then
        echo "[ERROR] The container stayed running because the Manager could not begin verified Funnel shutdown." >&2
        shutting_down=false
        return 70
      fi
    fi
    # Reap the non-root supervisor directly. Polling kill -0 can continue to
    # report a completed child until it is reaped, causing Docker to exhaust
    # its stop timeout and SIGKILL an otherwise verified shutdown. The
    # supervisor itself waits indefinitely when Manager Funnel cleanup fails,
    # so this remains fail closed while the root adapter is still available.
    wait "$service_pid" 2>/dev/null || true
    service_pid=""
  fi
  [[ -z "$adapter_pid" ]] || kill -TERM "$adapter_pid" 2>/dev/null || true
  [[ -z "$adapter_pid" ]] || wait "$adapter_pid" 2>/dev/null || true
}
request_termination() {
  termination_requested=true
}
trap request_termination TERM INT
trap 'stop_service || true' EXIT

if [[ "$FUNNEL_ADAPTER" == enabled ]]; then
  /opt/tautweekly/bin/funnel-adapter.sh &
  adapter_pid=$!
  for _ in $(seq 1 150); do
    [[ -S /run/tautweekly-remote-access/adapter.sock ]] && break
    kill -0 "$adapter_pid" 2>/dev/null || { wait "$adapter_pid"; exit $?; }
    sleep 0.1
  done
  [[ -S /run/tautweekly-remote-access/adapter.sock ]] || { echo "The public Funnel adapter did not become ready." >&2; exit 70; }
fi

gosu "$PUID:$PGID" /opt/tautweekly/run-service.sh &
service_pid=$!
status=0
while true; do
  if [[ "$termination_requested" == true ]]; then
    if stop_service; then
      status=0
      break
    fi
    termination_requested=false
    echo "[ERROR] Verified Funnel shutdown failed; the container remains running with its password boundary intact." >&2
  fi
  if wait "$service_pid"; then status=0; else status=$?; fi
  [[ "$termination_requested" == false ]] || continue
  kill -0 "$service_pid" 2>/dev/null || break
done
service_pid=""
stop_service || status=$?
trap - TERM INT EXIT
exit "$status"
