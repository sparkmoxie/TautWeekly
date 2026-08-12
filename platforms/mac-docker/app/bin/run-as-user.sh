#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "Usage: run-as-user.sh COMMAND [ARG...]" >&2
  exit 64
fi

if [[ "$(id -u)" -ne 0 ]]; then
  exec "$@"
fi

runtime_uid="${PUID:-1000}"
runtime_gid="${PGID:-1000}"
data_root="${TAUTWEEKLY_DATA_DIR:-/data}"
if ! [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ ]]; then
  echo "PUID and PGID must be numeric." >&2
  exit 64
fi
if [[ "$runtime_uid" == "0" || "$runtime_gid" == "0" ]]; then
  echo "PUID/PGID 0 is refused. Configure a non-root numeric identity, normally 1000:1000." >&2
  exit 64
fi

# Container exec bypasses entrypoint.sh and starts as root. Repair only stale
# root-owned entries within the dedicated data filesystem before dropping
# privileges. This recovers configurations and logs created by older wrappers
# without following symlinks or crossing into another mounted filesystem.
mkdir -p "$data_root"
find "$data_root" -xdev \( -uid 0 -o -gid 0 \) \
  -exec chown -h "$runtime_uid:$runtime_gid" {} +

exec gosu "$runtime_uid:$runtime_gid" "$@"
