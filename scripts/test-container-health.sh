#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
healthcheck="$repo_root/platforms/nas-docker/app/healthcheck.sh"
asset_source="$repo_root/platforms/nas-docker/app/assets-default/movies.gif"
python_bin="${PYTHON_BIN:-python3}"
temp_root="$(mktemp -d)"
data_root="$temp_root/data"
web_root="$temp_root/web"
server_log="$temp_root/http-server.log"
server_pid=""
pass_count=0

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$temp_root"
}
trap cleanup EXIT

mkdir -p "$data_root" "$web_root/assets"
printf '%s\n' 'TautWeekly preview test' >"$web_root/index.html"
cp "$asset_source" "$web_root/assets/movies.gif"

data_root_for_python="$data_root"
web_root_for_python="$web_root"
if [[ "$python_bin" == *.exe ]] && command -v cygpath >/dev/null 2>&1; then
  data_root_for_python="$(cygpath -w "$data_root")"
  web_root_for_python="$(cygpath -w "$web_root")"
fi

port="$("$python_bin" - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
"$python_bin" -m http.server "$port" --bind 127.0.0.1 --directory "$web_root_for_python" >"$server_log" 2>&1 &
server_pid=$!

for _ in {1..30}; do
  if curl -fsS --max-time 1 "http://127.0.0.1:${port}/" >/dev/null; then
    break
  fi
  sleep 0.1
done
curl -fsS --max-time 1 "http://127.0.0.1:${port}/" >/dev/null || {
  printf '[FAIL] Virtual preview server did not start.\n' >&2
  cat "$server_log" >&2
  exit 1
}

write_heartbeat() {
  local path="$1"
  local age_seconds="$2"
  local path_for_python="$path"
  if [[ "$python_bin" == *.exe ]] && command -v cygpath >/dev/null 2>&1; then
    path_for_python="$(cygpath -w "$path")"
  fi
  "$python_bin" - "$path_for_python" "$age_seconds" <<'PY'
import datetime, json, pathlib, sys
path=pathlib.Path(sys.argv[1])
age=float(sys.argv[2])
stamp=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=age)
path.write_text(json.dumps({'Utc': stamp.isoformat().replace('+00:00','Z')}), encoding='utf-8')
PY
}

run_healthcheck() {
  TAUTWEEKLY_DATA_DIR="$data_root_for_python" \
  TAUTWEEKLY_HEALTH_URL="http://127.0.0.1:${port}" \
  TAUTWEEKLY_PYTHON_BIN="$python_bin" \
    "$healthcheck"
}

expect_pass() {
  local label="$1"
  local output
  if ! output="$(run_healthcheck 2>&1)"; then
    printf '[FAIL] %s unexpectedly failed:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$label"
}

expect_fail_with() {
  local label="$1"
  local expected="$2"
  local output
  if output="$(run_healthcheck 2>&1)"; then
    printf '[FAIL] %s unexpectedly passed.\n' "$label" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf '[FAIL] %s did not report %q:\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$label"
}

write_heartbeat "$data_root/service-heartbeat.json" 0
expect_pass 'fresh supervisor heartbeat and preview root'

write_heartbeat "$data_root/scheduler-heartbeat.json" 3600
expect_pass 'stale scheduler progress does not fail container liveness'

rm "$web_root/assets/movies.gif"
asset_output="$(run_healthcheck 2>&1)"
grep -Fq '[WARN] Preview asset movies.gif is unavailable' <<<"$asset_output" || {
  printf '[FAIL] Missing preview asset did not emit its repair warning.\n%s\n' "$asset_output" >&2
  exit 1
}
pass_count=$((pass_count + 1))
printf '[PASS] missing decorative asset warns without failing liveness\n'
cp "$asset_source" "$web_root/assets/movies.gif"

write_heartbeat "$data_root/service-heartbeat.json" 300
expect_fail_with 'stale supervisor heartbeat' 'Service supervisor heartbeat is stale'

printf '%s\n' '{broken json' >"$data_root/service-heartbeat.json"
expect_fail_with 'corrupt supervisor heartbeat' 'Service supervisor heartbeat is unreadable'

rm "$data_root/service-heartbeat.json"
expect_fail_with 'missing supervisor heartbeat' 'Service supervisor heartbeat is missing'

write_heartbeat "$data_root/service-heartbeat.json" 0
expect_pass 'health recovers after supervisor heartbeat refresh'

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""
expect_fail_with 'stopped preview server' 'Preview root did not respond'

printf '[PASS] Container health regression suite completed with %d scenarios.\n' "$pass_count"
