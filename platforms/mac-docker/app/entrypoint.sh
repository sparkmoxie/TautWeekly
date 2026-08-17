#!/usr/bin/env bash
set -euo pipefail
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
UMASK_VALUE="${UMASK:-077}"
HOST_ADAPTER_API="${TAUTWEEKLY_HOST_ADAPTER_API:-legacy}"
umask "$UMASK_VALUE"

if [[ "$HOST_ADAPTER_API" != 2 ]]; then
  echo "[WARN] Host adapter API ${HOST_ADAPTER_API} is older than image API 2. The Manager can start, but update the host package or saved container template to restore current lifecycle and hardening settings." >&2
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
mkdir -p /data/assets /data/logs /data/manager /data/output/posters /data/output/media
cp -an /opt/tautweekly/assets-default/. /data/assets/ 2>/dev/null || true

# Browser previews are served from /data/output. Remove the old community
# symlink workaround when present, then maintain a real mirrored directory.
if [[ -L /data/output/assets ]]; then
  rm -f /data/output/assets
fi
mkdir -p /data/output/assets
cp -af /data/assets/. /data/output/assets/
mkdir -p /data/output/product-branding
cp -af /opt/tautweekly/product-branding/. /data/output/product-branding/

if [[ ! -f /data/config.example.json ]]; then
  cp /opt/tautweekly/config.example.json /data/config.example.json
fi
chown -R "$PUID:$PGID" /data
chmod 700 /data 2>/dev/null || true
[[ ! -f /data/config.json ]] || chmod 600 /data/config.json 2>/dev/null || true

exec gosu "$PUID:$PGID" /opt/tautweekly/run-service.sh
