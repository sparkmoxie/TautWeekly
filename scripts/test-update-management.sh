#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
stub_bin="$test_root/bin"
call_log="$test_root/calls.log"
state_file="$test_root/state"
holder_file="$test_root/holder"
metadata="$test_root/RELEASE-METADATA.txt"
mkdir -p "$stub_bin"
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local value="$1" expected="$2"
  grep -Fq -- "$expected" <<<"$value" || fail "missing expected output: $expected"
}

printf '%s\n' 'Repository version: 0.5.4' >"$metadata"
for checker in \
  "$repo_root/platforms/linux/check-release.sh" \
  "$repo_root/platforms/mac-docker/check-release.sh"; do
  output="$(TAUTWEEKLY_LATEST_RELEASE_VERSION=0.5.4 bash "$checker" "$metadata")"
  assert_contains "$output" 'This package is up to date.'
  output="$(TAUTWEEKLY_LATEST_RELEASE_VERSION=v0.5.5 bash "$checker" "$metadata")"
  assert_contains "$output" 'A stable update is available: 0.5.4 -> 0.5.5'
  printf '%s\n' 'Repository version: 0.5.6' >"$metadata"
  output="$(TAUTWEEKLY_LATEST_RELEASE_VERSION=0.5.5 bash "$checker" "$metadata")"
  assert_contains "$output" "newer than GitHub's latest stable release; no update is offered"
  printf '%s\n' 'Repository version: 0.5.4' >"$metadata"
done

cat >"$stub_bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$TAUTWEEKLY_TEST_CALL_LOG"

if [[ "$1" == compose ]]; then
  shift
  case "$1" in
    version) exit 0 ;;
    config)
      [[ "${2:-}" == --images ]] && printf '%s\n' 'ghcr.io/sparkmoxie/tautweekly:latest'
      ;;
    ps)
      [[ "${2:-}" == -q ]] && printf '%s\n' container-id
      ;;
    exec)
      if [[ "$*" == *' rm -f /data/.tautweekly-update-holder'* ]]; then rm -f "$TAUTWEEKLY_TEST_HOLDER"; exit 0; fi
      if [[ "$*" == *' test -s /data/.tautweekly-update-holder'* ]]; then test -s "$TAUTWEEKLY_TEST_HOLDER"; exit; fi
      if [[ "$*" == *' flock -n /data/.tautweekly-operation.lock '* ]]; then
        [[ "${TAUTWEEKLY_TEST_BUSY:-0}" == 1 ]] && exit 75
        printf '%s\n' held >"$TAUTWEEKLY_TEST_HOLDER"
        exit 0
      fi
      if [[ "$*" == *' sh -c if [ -s /data/.tautweekly-update-holder'* ]]; then rm -f "$TAUTWEEKLY_TEST_HOLDER"; exit 0; fi
      ;;
    pull) : ;;
    up) printf '%s\n' new >"$TAUTWEEKLY_TEST_STATE" ;;
    logs) : ;;
  esac
  exit 0
fi

if [[ "$1" == inspect ]]; then
  format="${3:-}"
  case "$format" in
    '{{.Image}}')
      [[ "$(cat "$TAUTWEEKLY_TEST_STATE")" == new ]] && printf '%s\n' sha256:new || printf '%s\n' sha256:old
      ;;
    '{{.State.Status}}') printf '%s\n' running ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') printf '%s\n' healthy ;;
  esac
  exit 0
fi

if [[ "$1" == image && "$2" == inspect ]]; then
  format="${4:-}"
  target="${5:-}"
  if [[ "$format" == '{{.Id}}' ]]; then
    printf '%s\n' sha256:new
  elif [[ "$target" == sha256:old ]]; then
    printf '%s\n' 0.5.4
  else
    printf '%s\n' 0.5.5
  fi
  exit 0
fi

if [[ "$1" == image && "$2" == tag ]]; then exit 0; fi
exit 0
STUB
chmod +x "$stub_bin/docker"

export TAUTWEEKLY_TEST_CALL_LOG="$call_log"
export TAUTWEEKLY_TEST_STATE="$state_file"
export TAUTWEEKLY_TEST_HOLDER="$holder_file"
export PATH="$stub_bin:$PATH"
printf '%s\n' old >"$state_file"
: >"$call_log"

output="$(bash "$repo_root/platforms/nas-docker/container-update.sh" check)"
assert_contains "$output" 'An update is staged.'
if grep -Fq 'docker compose up' "$call_log"; then fail 'check-update recreated the service'; fi

: >"$call_log"
output="$(bash "$repo_root/platforms/nas-docker/container-update.sh" apply)"
assert_contains "$output" 'Updated TautWeekly from 0.5.4 to 0.5.5'
grep -Fq 'docker compose up -d --no-build tautweekly' "$call_log" || fail 'apply did not use the staged image'
grep -Fq 'flock -n /data/.tautweekly-operation.lock sh -c' "$call_log" || fail 'apply did not hold the shared operation lock'

printf '%s\n' old >"$state_file"
: >"$call_log"
set +e
TAUTWEEKLY_TEST_BUSY=1 bash "$repo_root/platforms/nas-docker/container-update.sh" apply >/dev/null 2>&1
busy_status=$?
set -e
[[ "$busy_status" -eq 75 ]] || fail "busy update exited $busy_status instead of 75"
if grep -Fq 'docker compose pull' "$call_log"; then fail 'busy update pulled an image before refusing'; fi

set +e
bash "$repo_root/platforms/mac-docker/mac-update.sh" apply >/dev/null 2>&1
mac_unverified_status=$?
set -e
[[ "$mac_unverified_status" -eq 65 ]] || fail "macOS updater accepted an unversioned source checkout: $mac_unverified_status"

grep -Fq 'image: ${TAUTWEEKLY_IMAGE:-ghcr.io/sparkmoxie/tautweekly:latest}' \
  "$repo_root/platforms/nas-docker/compose.yaml" || fail 'NAS Compose no longer defaults to stable latest'
if grep -Fq 'io.containers.autoupdate' "$repo_root/platforms/freebsd-podman/rc.d/tautweekly"; then
  fail 'FreeBSD rc.d service still advertises systemd-only Podman auto-update'
fi
if grep -Eq '^\s*build:' "$repo_root/platforms/mac-docker/compose.yaml"; then
  fail 'macOS Compose still rebuilds bundled source as its update mechanism'
fi

printf '[PASS] Stable check-only and guarded container update behavior validated.\n'
