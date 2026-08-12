#!/usr/bin/env bash
set -euo pipefail

app_root="${TAUTWEEKLY_APP_DIR:-/opt/tautweekly}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
script_name="${1:-}"
shift || true

case "$script_name" in
  Setup-First.ps1|Verify-Setup.ps1|Manage-Library-Selection.ps1|Manage-User-Exclusions.ps1|View-Access-Roster.ps1|Repair-Assets.ps1|Schedule-Control.ps1) ;;
  *)
    echo "Unsupported TautWeekly helper script: ${script_name:-<missing>}" >&2
    exit 64
    ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
  exec "$script_dir/run-as-user.sh" "$0" "$script_name" "$@"
fi

exec pwsh -NoLogo -NoProfile -File "$app_root/$script_name" "$@"
