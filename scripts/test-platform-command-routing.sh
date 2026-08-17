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

for command_name in docker docker-compose runuser systemctl journalctl service podman pwsh open flock; do
  make_stub "$command_name"
done

export TAUTWEEKLY_TEST_CALL_LOG="$call_log"
export PATH="$stub_bin:$PATH"

# NAS/Unraid and macOS wrappers must route management and preview commands to
# the same in-container paths while preserving a user identifier as one arg.
bash "$repo_root/platforms/nas-docker/tautweekly.sh" list-libraries
assert_call 'docker compose version'
assert_call 'docker compose exec tautweekly /opt/tautweekly/bin/run-script.sh Manage-Library-Selection.ps1 -ListOnly'

reset_calls
bash "$repo_root/platforms/nas-docker/tautweekly.sh" preview 'Viewer With Spaces'
assert_call 'docker compose exec tautweekly /opt/tautweekly/bin/run-mode.sh Preview Viewer With Spaces'

reset_calls
bash "$repo_root/platforms/nas-docker/tautweekly.sh" shell
assert_call 'docker compose exec tautweekly /opt/tautweekly/bin/run-as-user.sh bash'

reset_calls
bash "$repo_root/platforms/mac-docker/tautweekly.sh" manage-libraries
assert_call 'docker compose exec tautweekly /opt/tautweekly/bin/run-script.sh Manage-Library-Selection.ps1'

reset_calls
bash "$repo_root/platforms/mac-docker/tautweekly.sh" manager-bootstrap
assert_call 'docker compose exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager'

reset_calls
bash "$repo_root/platforms/mac-docker/tautweekly.sh" open-manager
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

reset_calls
if run_privileged \
    "PATH=$PATH" \
    "TAUTWEEKLY_TEST_CALL_LOG=$call_log" \
    "TAUTWEEKLY_APP_DIR=/virtual/app" \
    "TAUTWEEKLY_DATA_DIR=$test_root/data" \
    "TAUTWEEKLY_CONFIG=$test_root/data/config.json" \
    bash "$repo_root/platforms/linux/tautweekly" manager-bootstrap; then
  assert_call "runuser -u tautweekly -- env TZ=Etc/UTC TAUTWEEKLY_APP_DIR=/virtual/app TAUTWEEKLY_DATA_DIR=$test_root/data TAUTWEEKLY_CONFIG=$test_root/data/config.json TAUTWEEKLY_PREVIEW_BASE_URL= /virtual/app/bin/tautweekly-manager access-bootstrap --data-dir $test_root/data/manager"
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
  assert_call 'podman exec -i virtual-tautweekly /opt/tautweekly/bin/run-script.sh Manage-Library-Selection.ps1 -ListOnly'
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
    sh "$repo_root/platforms/freebsd-podman/tautweekly" manager-bootstrap; then
  assert_call 'podman exec -i virtual-tautweekly /opt/tautweekly/bin/run-as-user.sh /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager'
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

  mkdir -p "$test_root/data/manager"
  manager_id='fixture123456789'
  manager_config="$test_root/data/manager/operation-$manager_id.config.json"
  manager_result="$test_root/data/manager/operation-$manager_id.result.json"
  printf '%s\n' '{}' >"$manager_config"
  reset_calls
  TAUTWEEKLY_APP_DIR=/virtual/app \
  TAUTWEEKLY_DATA_DIR="$test_root/data" \
  TAUTWEEKLY_CONFIG="$test_root/data/config.json" \
    bash "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" PreviewAll 17 \
      --manager-config "$manager_config" --manager-result "$manager_result" --no-open
  assert_call "pwsh -NoLogo -NoProfile -NonInteractive -File /virtual/app/TautWeekly.ps1 -Mode PreviewAll -ConfigPath $manager_config -UserId 17 -ResultPath $manager_result -NoOpen"

  if TAUTWEEKLY_APP_DIR=/virtual/app TAUTWEEKLY_DATA_DIR="$test_root/data" \
      bash "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" PreviewAll 17 \
        --manager-config "$test_root/data/config.json" --manager-result "$manager_result" --no-open \
        >/dev/null 2>&1; then
    fail 'run-mode accepted a Manager snapshot outside the private Manager directory'
  fi

  mkdir -p "$test_root/data/manager/operation-fixture123456789"
  printf '%s\n' '{}' >"$test_root/data/config.json"
  if TAUTWEEKLY_APP_DIR=/virtual/app TAUTWEEKLY_DATA_DIR="$test_root/data" \
      bash "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" PreviewAll 17 \
        --manager-config "$test_root/data/manager/operation-fixture123456789/../../config.json" \
        --manager-result "$test_root/data/manager/operation-fixture123456789/../../escaped.result.json" --no-open \
        >/dev/null 2>&1; then
    fail 'run-mode accepted traversal components in Manager operation paths'
  fi

  if TAUTWEEKLY_APP_DIR=/virtual/app TAUTWEEKLY_DATA_DIR="$test_root/data" \
      bash "$repo_root/platforms/nas-docker/app/bin/run-mode.sh" Preview one two >/dev/null 2>&1; then
    fail 'run-mode accepted two user identifiers'
  fi

else
  printf '[WARN] Shared operation-lock routing skipped because flock is unavailable.\n'
fi

# Container exec starts as root and bypasses entrypoint.sh. Simulate that
# boundary and require both launchers to re-exec under the configured PUID/PGID
# before a PowerShell helper can create persistent files.
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

for runtime_script in \
    "$repo_root/platforms/nas-docker/app/bin/run-script.sh" \
    "$repo_root/platforms/mac-docker/app/bin/run-script.sh"; do
  PUID=1234 PGID=5678 \
  PATH="$root_stub_bin:$PATH" \
  TAUTWEEKLY_APP_DIR=/virtual/app \
  TAUTWEEKLY_DATA_DIR="$root_data" \
    bash "$runtime_script" Verify-Setup.ps1
  assert_call "gosu 1234:5678 $runtime_script Verify-Setup.ps1"

  set +e
  PUID=1234 PGID=5678 PATH="$root_stub_bin:$PATH" \
    bash "$runtime_script" ../TautWeekly.ps1 >/dev/null 2>&1
  unsupported_status=$?
  set -e
  [[ "$unsupported_status" -eq 64 ]] || fail "run-script unsupported-helper preflight exited $unsupported_status instead of 64"
done

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
