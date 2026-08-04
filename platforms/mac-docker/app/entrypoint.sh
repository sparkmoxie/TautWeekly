#!/usr/bin/env bash
set -euo pipefail
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
UMASK_VALUE="${UMASK:-077}"
umask "$UMASK_VALUE"

if ! [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]]; then
  echo "PUID and PGID must be numeric." >&2
  exit 64
fi
if [[ "$PUID" == "0" || "$PGID" == "0" ]]; then
  echo "PUID/PGID 0 is refused. Configure a non-root numeric identity, normally 1000:1000." >&2
  exit 64
fi

if ! getent group "$PGID" >/dev/null 2>&1; then
  groupmod -o -g "$PGID" tautweekly
else
  existing_group="$(getent group "$PGID" | cut -d: -f1)"
  usermod -g "$existing_group" tautweekly
fi
usermod -o -u "$PUID" tautweekly

mkdir -p /data/assets /data/logs /data/output/posters /data/output/media
cp -an /opt/tautweekly/assets-default/. /data/assets/ 2>/dev/null || true

# Browser previews are served from /data/output. Remove the old community
# symlink workaround when present, then maintain a real mirrored directory.
if [[ -L /data/output/assets ]]; then
  rm -f /data/output/assets
fi
mkdir -p /data/output/assets
cp -af /data/assets/. /data/output/assets/

if [[ ! -f /data/config.example.json ]]; then
  cp /opt/tautweekly/config.example.json /data/config.example.json
fi
chown -R "$PUID:$PGID" /data
chmod 700 /data 2>/dev/null || true
[[ ! -f /data/config.json ]] || chmod 600 /data/config.json 2>/dev/null || true

exec gosu "$PUID:$PGID" /opt/tautweekly/run-service.sh
