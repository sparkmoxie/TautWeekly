#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_root="${1:-$repo_root/dist}"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

# Parse the exact generated release files without starting containers, reading
# a user's .env, creating host mounts, or requiring a Docker daemon.
docker compose version >/dev/null
mkdir -p "$test_root/nas" "$test_root/mac" "$test_root/standalone"

tar -xOzf "$dist_root/TautWeekly-nas-docker.tar.gz" \
  TautWeekly-nas-docker/compose.yaml >"$test_root/nas/compose.yaml"
tar -xOzf "$dist_root/TautWeekly-nas-docker.tar.gz" \
  TautWeekly-nas-docker/compose.qnap.yaml >"$test_root/nas/compose.qnap.yaml"
tar -xOzf "$dist_root/TautWeekly-mac-docker.tar.gz" \
  TautWeekly-mac-docker/compose.yaml >"$test_root/mac/compose.yaml"
tar -xOzf "$dist_root/TautWeekly-mac-docker.tar.gz" \
  TautWeekly-mac-docker/compose.registry.yaml >"$test_root/mac/compose.registry.yaml"
cp "$dist_root/TautWeekly-compose.yaml" "$test_root/standalone/server.yaml"
cp "$dist_root/TautWeekly-mac-compose.yaml" "$test_root/standalone/desktop.yaml"

for relative in nas/compose.yaml nas/compose.qnap.yaml mac/compose.yaml \
  mac/compose.registry.yaml standalone/server.yaml standalone/desktop.yaml; do
  docker compose --project-directory "$test_root" --project-name tautweekly-package-validation \
    --env-file /dev/null -f "$test_root/$relative" config --quiet
  printf '[PASS] Packaged Compose configuration: %s\n' "$relative"
done
