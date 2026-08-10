#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
stub_bin="$test_root/bin"
call_log="$test_root/calls.log"
mkdir -p "$stub_bin" "$test_root/data"
touch "$call_log"
chmod 0666 "$call_log"
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

assert_call() {
  local expected="$1"
  grep -Fqx -- "$expected" "$call_log" || {
    printf '%s\n' '--- recorded calls ---' >&2
    cat "$call_log" >&2
    fail "missing routed call: $expected"
  }
}

reset_calls() {
  : >"$call_log"
}

make_stub() {
  local name="$1"
  cat >"$stub_bin/$name" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >>"$TAUTWEEKLY_TEST_CALL_LOG"
STUB
  chmod +x "$stub_bin/$name"
}

for command_name in docker docker-compose runuser systemctl journalctl service podman pwsh open; do
  make_stub "$command_name"
done

export TAUTWEEKLY_TEST_CALL_LOG="$call_log"
export PATH="$stub_bin:$PATH"

# NAS/Unraid and macOS wrappers must route management and preview commands to
# the same in-container paths while preserving a user identifier as one arg.
bash "$repo_root/platforms/nas-docker/tautweekly.sh" list-libraries
assert_call 'docker compose version'
assert_call 'docker compose exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1 -ListOnly'

reset_calls
bash "$repo_root/platforms/nas-docker/tautweekly.sh" preview 'Viewer With Spaces'
assert_call 'docker compose exec tautweekly /opt/tautweekly/bin/run-mode.sh Preview Viewer With Spaces'

reset_calls
bash "$repo_root/platforms/mac-docker/tautweekly.sh" manage-libraries
assert_call 'docker compose exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1'

reset_calls
bash "$repo_root/platforms/mac-docker/tautweekly.sh" open-preview
assert_call 'open http://localhost:8787/'

# Native Linux and FreeBSD control paths require root by design. Run their
# harmless command-routing paths under sudo when the hosted runner is not root.
run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    env "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo env "$@"
  else
    return 77
  fi
}

reset_calls
if run_privileged \
    "PATH=$PATH" \
    "TAUTWEEKLY_TEST_CALL_LOG=$call_log" \
    "TAUTWEEKLY_APP_DIR=/virtual/app" \
    "TAUTWEEKLY_DATA_DIR=$test_root/data" \
    "TAUTWEEKLY_CONFIG=$test_root/data/config.json" \
    bash "$repo_root/platforms/linux/tautweekly" list-libraries; then
  assert_call "runuser -u tautweekly -- env TZ=Etc/UTC TAUTWEEKLY_APP_DIR=/virtual/app TAUTWEEKLY_DATA_DIR=$test_root/data TAUTWEEKLY_CONFIG=$test_root/data/config.json TAUTWEEKLY_PREVIEW_BASE_URL= pwsh -NoLogo -NoProfile -File /virtual/app/Manage-Library-Selection.ps1 -ConfigPath $test_root/data/config.json -ListOnly"
else
  status=$?
  [[ "$status" -eq 77 ]] || fail "native Linux routing exited $status"
  printf '[WARN] Native Linux root-only routing skipped because sudo is unavailable.\n'
fi

freebsd_env="$test_root/freebsd.env"
cat >"$freebsd_env" <<EOF
TAUTWEEKLY_CONTAINER=virtual-tautweekly
TAUTWEEKLY_DATA_DIR=$test_root/data
TAUTWEEKLY_IMAGE=ghcr.io/example/virtual:latest
TAUTWEEKLY_PODMAN_BIN=$stub_bin/podman
EOF

reset_calls
if run_privileged \
    "PATH=$PATH" \
    "TAUTWEEKLY_TEST_CALL_LOG=$call_log" \
    "TAUTWEEKLY_ENV_FILE=$freebsd_env" \
    "TAUTWEEKLY_PODMAN_BIN=$stub_bin/podman" \
    sh "$repo_root/platforms/freebsd-podman/tautweekly" list-libraries; then
  assert_call 'podman exec -i virtual-tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1 -ListOnly'
else
  status=$?
  [[ "$status" -eq 77 ]] || fail "FreeBSD routing exited $status"
  printf '[WARN] FreeBSD root-only routing skipped because sudo is unavailable.\n'
fi

reset_calls
if run_privileged \
    "PATH=$PATH" \
    "TAUTWEEKLY_TEST_CALL_LOG=$call_log" \
    "TAUTWEEKLY_ENV_FILE=$freebsd_env" \
    "TAUTWEEKLY_PODMAN_BIN=$stub_bin/podman" \
    sh "$repo_root/platforms/freebsd-podman/tautweekly" update; then
  assert_call 'podman pull --os=linux ghcr.io/example/virtual:latest'
  assert_call 'service tautweekly restart'
fi

# The shared container run-mode wrapper must preserve arguments and reject a
# second positional user rather than silently shifting command meaning.
if command -v flock >/dev/null 2>&1; then
  reset_calls
  TAUTWEEKLY_APP_DIR=/virtual/app \
  TAUTWEEKLY_DATA_DIR="$test_root/data" \
  TAUTWEEKLY_CONFIG="$test_root/data/config.json" \
    bash "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" Preview 'Viewer With Spaces'
  assert_call "pwsh -NoLogo -NoProfile -NonInteractive -File /virtual/app/TautWeekly.ps1 -Mode Preview -ConfigPath $test_root/data/config.json -UserId Viewer With Spaces"

  if TAUTWEEKLY_APP_DIR=/virtual/app TAUTWEEKLY_DATA_DIR="$test_root/data" \
      bash "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" Preview one two >/dev/null 2>&1; then
    fail 'run-mode accepted two user identifiers'
  fi

else
  printf '[WARN] Shared operation-lock routing skipped because flock is unavailable.\n'
fi

# Container exec starts as root and bypasses entrypoint.sh. Simulate that
# boundary and require run-mode to re-exec under the configured PUID/PGID
# before creating its operation lock or output directories.
root_stub_bin="$test_root/root-bin"
root_data="$test_root/root-data"
mkdir -p "$root_stub_bin" "$root_data"
cat >"$root_stub_bin/id" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == '-u' ]] || exit 64
printf '0\n'
STUB
cat >"$root_stub_bin/gosu" <<'STUB'
#!/usr/bin/env bash
printf 'gosu %s\n' "$*" >>"$TAUTWEEKLY_TEST_CALL_LOG"
STUB
chmod +x "$root_stub_bin/id" "$root_stub_bin/gosu"
reset_calls
for runtime_wrapper in \
    "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" \
    "$repo_root/platforms/mac-docker/app/bin/run-mode.sh"; do
  PUID=1234 PGID=5678 \
  PATH="$root_stub_bin:$PATH" \
  TAUTWEEKLY_APP_DIR=/virtual/app \
  TAUTWEEKLY_DATA_DIR="$root_data" \
  TAUTWEEKLY_CONFIG="$root_data/config.json" \
    bash "$runtime_wrapper" Preview 'Viewer With Spaces'
  assert_call "gosu 1234:5678 $runtime_wrapper Preview Viewer With Spaces"
done
[[ ! -e "$root_data/.tautweekly-operation.lock" ]] || fail 'run-mode wrote persistent data before dropping root privileges'

# Installer preflight must fail before any system mutation for invalid targets.
set +e
bash "$repo_root/platforms/linux/install-linux.sh" invalid >/dev/null 2>&1
linux_preflight_status=$?
set -e
[[ "$linux_preflight_status" -eq 64 ]] || fail "Linux installer invalid-mode preflight exited $linux_preflight_status instead of 64"

set +e
sh "$repo_root/platforms/freebsd-podman/install-freebsd.sh" >/dev/null 2>&1
freebsd_preflight_status=$?
set -e
[[ "$freebsd_preflight_status" -eq 69 || "$freebsd_preflight_status" -eq 77 ]] || fail "FreeBSD installer preflight exited unexpectedly: $freebsd_preflight_status"

printf '[PASS] Platform command routing and installer preflight behavior validated.\n'
