#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="$repo_root/platforms/nas-docker/app/bin/runtime-profile.sh"
pass_count=0

expect_profile() {
  local label="$1"
  local profile="$2"
  local package_kind="$3"
  local expected="$4"
  local output
  output="$(env -u TAUTWEEKLY_MANAGER_RUNTIME_MODE \
    TAUTWEEKLY_RUNTIME_PROFILE="$profile" \
    TAUTWEEKLY_PACKAGE_KIND="$package_kind" \
    "$selector")"
  if [[ "$output" != "$expected" ]]; then
    printf '[FAIL] %s\nexpected:\n%s\nactual:\n%s\n' "$label" "$expected" "$output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$label"
}

expect_refusal() {
  local label="$1"
  local profile="$2"
  local package_kind="$3"
  local expected="$4"
  local output status
  set +e
  output="$(env -u TAUTWEEKLY_MANAGER_RUNTIME_MODE \
    TAUTWEEKLY_RUNTIME_PROFILE="$profile" \
    TAUTWEEKLY_PACKAGE_KIND="$package_kind" \
    "$selector" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne 64 || "$output" != *"$expected"* ]]; then
    printf '[FAIL] %s: status=%s output=%s\n' "$label" "$status" "$output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
  printf '[PASS] %s\n' "$label"
}

expect_profile 'explicit desktop' desktop container-desktop $'profile=desktop\npackage=container-desktop\nmanager=mac'
expect_profile 'explicit server' server container-compose $'profile=server\npackage=container-compose\nmanager=nas'
expect_profile 'explicit Unraid' unraid unraid $'profile=unraid\npackage=unraid\nmanager=nas'
expect_profile 'legacy Mac registry inference' '' mac-docker-registry $'profile=desktop\npackage=mac-docker-registry\nmanager=mac'
expect_profile 'legacy NAS inference' '' nas-docker $'profile=server\npackage=nas-docker\nmanager=nas'
expect_profile 'generic compatibility default' '' '' $'profile=server\npackage=docker-compatible\nmanager=nas'

expect_refusal 'unknown profile refusal' future container-compose 'must be desktop, server, or unraid'
expect_refusal 'desktop/package mismatch refusal' desktop container-compose 'desktop is incompatible'
expect_refusal 'Unraid/package mismatch refusal' unraid nas-docker "requires package kind 'unraid'"

printf '[PASS] Runtime profile regression suite completed with %d scenarios.\n' "$pass_count"
