#!/usr/bin/env bash
set -euo pipefail
curl -fsS --max-time 3 http://127.0.0.1:8080/ >/dev/null
curl -fsS --max-time 3 http://127.0.0.1:8080/assets/movies.gif >/dev/null
[[ -f /data/scheduler-heartbeat.json ]]
python3 - <<'PY'
import json, datetime, sys
p='/data/scheduler-heartbeat.json'
with open(p,'r',encoding='utf-8-sig') as f: d=json.load(f)
ts=d.get('Utc','').replace('Z','+00:00')
try: t=datetime.datetime.fromisoformat(ts)
except Exception: sys.exit(1)
if t.tzinfo is None: t=t.replace(tzinfo=datetime.timezone.utc)
age=(datetime.datetime.now(datetime.timezone.utc)-t.astimezone(datetime.timezone.utc)).total_seconds()
sys.exit(0 if age < 240 else 1)
PY
