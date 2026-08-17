#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-$repo_root/dist/TautWeekly-linux.tar.gz}"
test_root="$(mktemp -d)"
manager_pid=""

cleanup() {
  if [[ -n "$manager_pid" ]] && kill -0 "$manager_pid" 2>/dev/null; then
    kill -TERM "$manager_pid" 2>/dev/null || true
    wait "$manager_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

[[ -f "$archive" ]] || fail "Linux release archive not found: $archive"
tar -xzf "$archive" -C "$test_root"
package_root="$test_root/TautWeekly-linux"

case "$(uname -m)" in
  x86_64|amd64) manager_arch=amd64 ;;
  aarch64|arm64) manager_arch=arm64 ;;
  *) fail "Linux package smoke test requires a supported 64-bit host architecture" ;;
esac

manager="$package_root/manager/tautweekly-manager-linux-$manager_arch"
[[ -x "$manager" ]] || fail "Packaged $manager_arch Manager is not executable"
"$manager" version | grep -Eq '^TautWeekly Manager (ci|[0-9]+\.[0-9]+\.[0-9]+)$' || fail 'Packaged Manager version is missing or malformed'
grep -Fq 'authenticated native Linux Manager endpoint' "$package_root/app/preview-home.html" || fail 'Linux-specific Manager landing page is missing'
if grep -Eq 'Docker Compose|Unraid container Console' "$package_root/app/preview-home.html"; then
  fail 'Linux preview landing page contains container-only setup language'
fi

data_root="$test_root/data"
mkdir -p "$data_root/manager"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
log_file="$test_root/manager.log"
"$manager" serve \
  --runtime-mode linux \
  --listen "127.0.0.1:$port" \
  --tautweekly-root "$package_root/app" \
  --runtime-root "$data_root" \
  --data-dir "$data_root/manager" \
  >"$log_file" 2>&1 &
manager_pid=$!

ready=false
for _ in {1..50}; do
  if curl --fail --silent --max-time 1 "http://127.0.0.1:$port/health/live" >/dev/null; then
    ready=true
    break
  fi
  kill -0 "$manager_pid" 2>/dev/null || break
  sleep 0.1
done
[[ "$ready" == true ]] || {
  sed -n '1,80p' "$log_file" >&2
  fail 'Packaged Linux Manager did not become ready'
}

status="$(curl --silent --output "$test_root/unauthorized.json" --write-out '%{http_code}' "http://127.0.0.1:$port/api/v1/capabilities")"
[[ "$status" == 401 ]] || fail "Linux Manager allowed unauthenticated capabilities access (HTTP $status)"

bootstrap_token="$("$manager" access-bootstrap --data-dir "$data_root/manager")"
[[ "$bootstrap_token" =~ ^[A-Za-z0-9_-]{20,}$ ]] || fail 'Explicit bootstrap command did not return a bounded one-time token'
if grep -Fq -- "$bootstrap_token" "$log_file"; then
  fail 'Manager log exposed the one-time bootstrap token'
fi

kill -TERM "$manager_pid"
for _ in {1..50}; do
  kill -0 "$manager_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$manager_pid" 2>/dev/null; then
  fail 'Packaged Linux Manager did not stop gracefully'
fi
wait "$manager_pid"
manager_pid=""

printf '[PASS] Packaged native Linux Manager boot, authentication, token redaction, adapter, and shutdown validated.\n'
