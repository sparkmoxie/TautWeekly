#!/usr/bin/env bash
set -euo pipefail
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
health_base_url="${TAUTWEEKLY_HEALTH_URL:-http://127.0.0.1:8080}"
heartbeat_path="$data_root/service-heartbeat.json"
heartbeat_max_age="${TAUTWEEKLY_HEALTH_HEARTBEAT_MAX_SECONDS:-90}"
python_bin="${TAUTWEEKLY_PYTHON_BIN:-python3}"

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

[[ "$heartbeat_max_age" =~ ^[0-9]+$ ]] || fail 'TAUTWEEKLY_HEALTH_HEARTBEAT_MAX_SECONDS must be a positive integer.'
(( heartbeat_max_age > 0 )) || fail 'TAUTWEEKLY_HEALTH_HEARTBEAT_MAX_SECONDS must be greater than zero.'

if ! curl -fsS --max-time 3 "${health_base_url%/}/" >/dev/null; then
  fail "Preview root did not respond at ${health_base_url%/}/."
fi

if ! curl -fsS --max-time 3 "${health_base_url%/}/assets/movies.gif" >/dev/null; then
  printf '[WARN] Preview asset movies.gif is unavailable; run the packaged repair-assets command.\n' >&2
fi

[[ -f "$heartbeat_path" ]] || fail "Service supervisor heartbeat is missing: $heartbeat_path"
"$python_bin" - "$heartbeat_path" "$heartbeat_max_age" <<'PY'
import json, datetime, sys
path=sys.argv[1]
max_age=float(sys.argv[2])
try:
    with open(path,'r',encoding='utf-8-sig') as f:
        data=json.load(f)
    raw=str(data.get('Utc','')).replace('Z','+00:00')
    timestamp=datetime.datetime.fromisoformat(raw)
    if timestamp.tzinfo is None:
        timestamp=timestamp.replace(tzinfo=datetime.timezone.utc)
except Exception as exc:
    print(f'[FAIL] Service supervisor heartbeat is unreadable: {exc}', file=sys.stderr)
    sys.exit(1)
age=(datetime.datetime.now(datetime.timezone.utc)-timestamp.astimezone(datetime.timezone.utc)).total_seconds()
if age < max_age:
    sys.exit(0)
print(f'[FAIL] Service supervisor heartbeat is stale: age={age:.1f}s limit={max_age:.0f}s', file=sys.stderr)
sys.exit(1)
PY
