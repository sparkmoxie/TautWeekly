#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -d '' shell_files < <(find "$repo_root/platforms" "$repo_root/scripts" -type f \( -name '*.sh' -o -name '*.command' \) -print0)

for file in "${shell_files[@]}"; do
  bash -n "$file"
done

command -v shellcheck >/dev/null 2>&1 || {
  echo "ShellCheck is required." >&2
  exit 1
}

shellcheck --severity=warning "${shell_files[@]}"
printf '[PASS] bash -n and ShellCheck validated %d file(s).\n' "${#shell_files[@]}"
