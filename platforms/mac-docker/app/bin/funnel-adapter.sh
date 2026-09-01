#!/usr/bin/env bash
set -euo pipefail

state_root="${TAUTWEEKLY_TAILSCALE_STATE_DIR:-/var/lib/tautweekly-tailscale}"
daemon_socket="/run/tautweekly-tailscale/tailscaled.sock"
manager_uid="${PUID:-1000}"
manager_gid="${PGID:-1000}"
tailscaled_pid=""
helper_pid=""

fail() { printf '[ERROR] Public Funnel adapter: %s\n' "$1" >&2; exit 64; }
[[ "$(id -u)" -eq 0 ]] || fail 'the adapter must start as container root.'
[[ "${TAUTWEEKLY_FUNNEL_ADAPTER:-disabled}" == enabled ]] || fail 'TAUTWEEKLY_FUNNEL_ADAPTER must be exactly enabled.'
[[ "$manager_uid" =~ ^[0-9]+$ && "$manager_gid" =~ ^[0-9]+$ ]] || fail 'PUID and PGID must be numeric.'
[[ "$manager_uid" != 0 && "$manager_gid" != 0 ]] || fail 'the Manager identity must remain non-root.'
for forbidden in TS_AUTHKEY TS_AUTH_KEY TS_CLIENT_ID TS_CLIENT_SECRET TS_ID_TOKEN TS_AUDIENCE TS_AUTHKEY_FILE; do
  [[ -z "${!forbidden:-}" ]] || fail "$forbidden is refused; sign in interactively with the package command instead."
done
[[ ! -L "$state_root" ]] || fail 'the Tailscale state directory may not be a symlink.'
mkdir -p "$state_root" /run/tautweekly-tailscale /run/tautweekly-remote-access
chown 0:0 "$state_root" /run/tautweekly-tailscale /run/tautweekly-remote-access
chmod 700 "$state_root" /run/tautweekly-tailscale
# Manager needs traversal to its UID-owned 0600 socket, but cannot list or
# modify the root-owned adapter directory.
chmod 711 /run/tautweekly-remote-access
stop_adapter() {
  [[ -z "$helper_pid" ]] || kill -TERM "$helper_pid" 2>/dev/null || true
  [[ -z "$tailscaled_pid" ]] || kill -TERM "$tailscaled_pid" 2>/dev/null || true
  [[ -z "$helper_pid" ]] || wait "$helper_pid" 2>/dev/null || true
  [[ -z "$tailscaled_pid" ]] || wait "$tailscaled_pid" 2>/dev/null || true
}
trap stop_adapter TERM INT EXIT
/usr/local/bin/tailscaled --tun=userspace-networking --state="$state_root/tailscaled.state" --socket="$daemon_socket" --port=0 >/dev/null 2>&1 &
tailscaled_pid=$!
for _ in $(seq 1 100); do
  [[ -S "$daemon_socket" ]] && break
  kill -0 "$tailscaled_pid" 2>/dev/null || fail 'the official Tailscale daemon stopped before its private socket became ready.'
  sleep 0.1
done
[[ -S "$daemon_socket" ]] || fail 'the official Tailscale daemon socket did not become ready.'
TAUTWEEKLY_REMOTE_ACCESS_UID="$manager_uid" /opt/tautweekly/bin/tautweekly-manager remote-access-sidecar &
helper_pid=$!
for _ in $(seq 1 100); do
  [[ -S /run/tautweekly-remote-access/adapter.sock ]] && break
  kill -0 "$helper_pid" 2>/dev/null || fail 'the fixed-operation Manager adapter stopped before its socket became ready.'
  sleep 0.1
done
[[ -S /run/tautweekly-remote-access/adapter.sock ]] || fail 'the fixed-operation Manager adapter socket did not become ready.'
printf '[INFO] Optional Tailscale Funnel adapter is ready for explicit interactive sign-in.\n'
wait "$helper_pid"
