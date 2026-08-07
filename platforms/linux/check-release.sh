#!/usr/bin/env bash
set -euo pipefail

metadata_path="${1:-/opt/tautweekly/RELEASE-METADATA.txt}"
release_api="${TAUTWEEKLY_RELEASE_API_URL:-https://api.github.com/repos/sparkmoxie/TautWeekly/releases/latest}"

current_version=""
if [[ -r "$metadata_path" ]]; then
  current_version="$(sed -n 's/^Repository version:[[:space:]]*v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "$metadata_path" | head -n 1)"
fi

if [[ -n "${TAUTWEEKLY_LATEST_RELEASE_VERSION:-}" ]]; then
  latest_version="${TAUTWEEKLY_LATEST_RELEASE_VERSION#v}"
else
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to check GitHub Releases." >&2
    exit 69
  }
  response="$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$release_api")"
  latest_version="$(printf '%s' "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
fi

if [[ ! "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "GitHub did not return a valid stable release version." >&2
  exit 65
fi

if [[ -z "$current_version" ]]; then
  echo "Installed package: unknown (release metadata is unavailable)"
  echo "Latest stable release: $latest_version"
  echo "Use an official release archive before applying an update."
  exit 0
fi

echo "Installed package: $current_version"
echo "Latest stable release: $latest_version"
version_greater_than() {
  local left_major left_minor left_patch right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<<"$1"
  IFS=. read -r right_major right_minor right_patch <<<"$2"
  (( 10#$left_major > 10#$right_major )) && return 0
  (( 10#$left_major < 10#$right_major )) && return 1
  (( 10#$left_minor > 10#$right_minor )) && return 0
  (( 10#$left_minor < 10#$right_minor )) && return 1
  (( 10#$left_patch > 10#$right_patch ))
}

if [[ "$current_version" == "$latest_version" ]]; then
  echo "This package is up to date."
elif version_greater_than "$current_version" "$latest_version"; then
  echo "This package is newer than GitHub's latest stable release; no update is offered."
else
  echo "A stable update is available: $current_version -> $latest_version"
  echo "Release: https://github.com/sparkmoxie/TautWeekly/releases/tag/v$latest_version"
fi
