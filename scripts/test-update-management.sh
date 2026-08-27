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
    up)
      printf '%s\n' new >"$TAUTWEEKLY_TEST_STATE"
      if [[ "${TAUTWEEKLY_TEST_UPDATE_BAD:-0}" == 1 && -n "${TAUTWEEKLY_TEST_PACKAGE_ROOT:-}" ]]; then
        printf '%s\n' '#!/usr/bin/env bash' 'exit 99' >"$TAUTWEEKLY_TEST_PACKAGE_ROOT/package-update.sh"
      fi
      ;;
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
    '{{.State.Status}}')
      if [[ "${TAUTWEEKLY_TEST_UPDATE_BAD:-0}" == 1 && "$(cat "$TAUTWEEKLY_TEST_STATE")" == new ]]; then printf '%s\n' exited; else printf '%s\n' running; fi
      ;;
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
      if [[ "${TAUTWEEKLY_TEST_UPDATE_BAD:-0}" == 1 && "$(cat "$TAUTWEEKLY_TEST_STATE")" == new ]]; then printf '%s\n' unhealthy; else printf '%s\n' healthy; fi
      ;;
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

release_assets="$test_root/release-assets"
candidate="$test_root/candidate/TautWeekly-nas-docker"
mkdir -p "$release_assets" "$candidate/data"
cp "$repo_root/platforms/shared/package-update.sh" "$candidate/package-update.sh"
cp "$repo_root/platforms/nas-docker/container-update.sh" "$candidate/container-update.sh"
printf '%s\n' 'services: { tautweekly: { image: synthetic:new } }' >"$candidate/compose.yaml"
printf '%s\n' 'Repository version: 0.5.5' >"$candidate/RELEASE-METADATA.txt"
printf '%s\n' 'candidate-env-must-not-replace-private-data' >"$candidate/.env"
printf '%s\n' 'candidate-config-must-not-replace-private-data' >"$candidate/data/config.json"
chmod +x "$candidate/package-update.sh" "$candidate/container-update.sh"
(
  cd "$candidate"
  for path in .env RELEASE-METADATA.txt compose.yaml container-update.sh data/config.json package-update.sh; do
    printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$path"
  done >RELEASE-FILES.txt
)
(
  cd "$test_root/candidate"
  tar -czf "$release_assets/TautWeekly-nas-docker.tar.gz" TautWeekly-nas-docker
)
printf '%s  %s\n' \
  "$(sha256sum "$release_assets/TautWeekly-nas-docker.tar.gz" | awk '{print $1}')" \
  'TautWeekly-nas-docker.tar.gz' >"$release_assets/SHA256SUMS.txt"

make_old_package() {
  local target="$1" path
  mkdir -p "$target/data"
  cp "$repo_root/platforms/shared/package-update.sh" "$target/package-update.sh"
  cp "$repo_root/platforms/nas-docker/container-update.sh" "$target/container-update.sh"
  printf '%s\n' 'services: { tautweekly: { image: synthetic:old } }' >"$target/compose.yaml"
  printf '%s\n' 'Repository version: 0.5.4' >"$target/RELEASE-METADATA.txt"
  printf '%s\n' 'private-env-sentinel' >"$target/.env"
  printf '%s\n' 'private-config-sentinel' >"$target/data/config.json"
  printf '%s\n' 'retired-release-file' >"$target/retired.txt"
  chmod +x "$target/package-update.sh" "$target/container-update.sh"
  (
    cd "$target"
    for path in RELEASE-METADATA.txt compose.yaml container-update.sh package-update.sh retired.txt; do
      printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$path"
    done >RELEASE-FILES.txt
  )
}

package_root="$test_root/installed-success"
make_old_package "$package_root"
printf '%s\n' old >"$state_file"
: >"$call_log"
output="$(
  cd "$package_root"
  TAUTWEEKLY_PACKAGE_KIND=nas-docker \
    TAUTWEEKLY_PACKAGE_ROOT="$package_root" \
    TAUTWEEKLY_LATEST_RELEASE_VERSION=0.5.5 \
    TAUTWEEKLY_RELEASE_ASSET_DIR="$release_assets" \
    bash ./package-update.sh apply
)"
assert_contains "$output" 'Verified stable TautWeekly-nas-docker package version 0.5.5.'
assert_contains "$output" 'Host package and runtime update committed.'
grep -Fq 'Repository version: 0.5.5' "$package_root/RELEASE-METADATA.txt" || fail 'verified package metadata was not installed'
grep -Fq 'synthetic:new' "$package_root/compose.yaml" || fail 'release-owned Compose file was not updated'
[[ ! -e "$package_root/retired.txt" ]] || fail 'retired release-owned file was not removed'
grep -Fq 'private-env-sentinel' "$package_root/.env" || fail 'package update replaced private .env'
grep -Fq 'private-config-sentinel' "$package_root/data/config.json" || fail 'package update replaced private data'
grep -Fq 'docker compose up -d --no-build --force-recreate tautweekly' "$call_log" || fail 'host-package update did not force recreation for new Compose settings'

rollback_root="$test_root/installed-rollback"
make_old_package "$rollback_root"
printf '%s\n' old >"$state_file"
: >"$call_log"
set +e
(
  cd "$rollback_root"
  TAUTWEEKLY_TEST_UPDATE_BAD=1 \
    TAUTWEEKLY_TEST_PACKAGE_ROOT="$rollback_root" \
    TAUTWEEKLY_PACKAGE_KIND=nas-docker \
    TAUTWEEKLY_PACKAGE_ROOT="$rollback_root" \
    TAUTWEEKLY_LATEST_RELEASE_VERSION=0.5.5 \
    TAUTWEEKLY_RELEASE_ASSET_DIR="$release_assets" \
    bash ./package-update.sh apply
) >/dev/null 2>&1
rollback_status=$?
set -e
[[ "$rollback_status" -eq 70 ]] || fail "failed package/runtime update exited $rollback_status instead of 70"
grep -Fq 'Repository version: 0.5.4' "$rollback_root/RELEASE-METADATA.txt" || fail 'failed update did not restore package metadata'
grep -Fq 'synthetic:old' "$rollback_root/compose.yaml" || fail 'failed update did not restore Compose file'
grep -Fq 'retired-release-file' "$rollback_root/retired.txt" || fail 'failed update did not restore retired release-owned file'
grep -Fq 'private-env-sentinel' "$rollback_root/.env" || fail 'failed update changed private .env'
grep -Fq 'private-config-sentinel' "$rollback_root/data/config.json" || fail 'failed update changed private data'

grep -Fq 'image: ${TAUTWEEKLY_IMAGE:-ghcr.io/sparkmoxie/tautweekly:__TAUTWEEKLY_RELEASE_VERSION__}' \
  "$repo_root/platforms/nas-docker/compose.yaml" || fail 'NAS release Compose no longer defaults to the full-semver release token'
if grep -Fq 'io.containers.autoupdate' "$repo_root/platforms/freebsd-podman/rc.d/tautweekly"; then
  fail 'FreeBSD rc.d service still advertises systemd-only Podman auto-update'
fi
if grep -Eq '^\s*build:' "$repo_root/platforms/mac-docker/compose.yaml"; then
  fail 'macOS Compose still rebuilds bundled source as its update mechanism'
fi

printf '[PASS] Stable check-only and guarded container update behavior validated.\n'
