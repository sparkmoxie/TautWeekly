#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
package_root="$(pwd -P)"

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; return; fi
  if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"; return; fi
  echo "Docker Compose was not found." >&2; exit 1
}

prompt_user() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then read -r -p "UserId, username, friendly name, or email: " value; fi
  [[ -n "$value" ]] || { echo "A user identifier is required." >&2; exit 64; }
  printf '%s' "$value"
}

confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

package_update() {
  local updater="$package_root/package-update.sh"
  [[ -f "$updater" ]] || updater="$package_root/../shared/package-update.sh"
  [[ -f "$updater" ]] || {
    echo "The host-package updater is missing. Extract a complete verified release archive." >&2
    exit 66
  }
  export TAUTWEEKLY_PACKAGE_KIND=mac-docker
  export TAUTWEEKLY_PACKAGE_ROOT="$package_root"
  exec bash "$updater" "$@"
}

remote_cleanup() {
  if compose_cmd ps --status running --services 2>/dev/null | grep -Fxq tautweekly; then
    compose_cmd exec -T tautweekly /opt/tautweekly/bin/tautweekly-funnel disable
  fi
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  install) exec ./mac-install.sh ;;
  up|start) compose_cmd up -d ;;
  down|stop) remote_cleanup; compose_cmd down ;;
  restart) remote_cleanup; compose_cmd up -d --no-build --force-recreate tautweekly ;;
  status) compose_cmd ps ;;
  logs) compose_cmd logs -f --tail=200 tautweekly ;;
  shell) compose_cmd exec tautweekly /opt/tautweekly/bin/run-as-user.sh bash ;;
  setup) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Setup-First.ps1 ;;
  verify) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Verify-Setup.ps1 ;;
  cache-status) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Cache-Diagnostics.ps1 -DataRoot /data "$@" ;;
  cache-refresh) compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh CacheWarm ;;
  list-users) compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh ListUsers ;;
  exclude-users|manage-exclusions) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Manage-User-Exclusions.ps1 ;;
  list-libraries) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Manage-Library-Selection.ps1 -ListOnly ;;
  libraries|manage-libraries) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Manage-Library-Selection.ps1 ;;
  preview)
    user="$(prompt_user "${1:-}")"
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh Preview "$user"
    ;;
  preview-all)
    user="$(prompt_user "${1:-}")"
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh PreviewAll "$user"
    ;;
  send-test)
    user="$(prompt_user "${1:-}")"
    confirm "Send one test email to TestEmail using $user?" || exit 0
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh SendTest "$user"
    ;;
  send-test-all)
    user="$(prompt_user "${1:-}")"
    confirm "Send all six regression emails to TestEmail using $user?" || exit 0
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh SendTestAll "$user"
    ;;
  welcome)
    user="$(prompt_user "${1:-}")"
    confirm "Send the real one-off welcome to the selected Plex user's email?" || exit 0
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh SendWelcome "$user" --confirm-welcome
    ;;
  send-all)
    echo "WARNING: This sends one real newsletter to every eligible Plex user."
    confirm "Have you reviewed a current TestEmail and do you want to continue?" || exit 0
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh SendAll --confirm-send-all
    ;;
  roster) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh View-Access-Roster.ps1 ;;
  repair-assets) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Repair-Assets.ps1 ;;
  manager-bootstrap)
    compose_cmd exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
      /opt/tautweekly/bin/tautweekly-manager access-bootstrap --data-dir /data/manager
    ;;
  manager-reset-access)
    echo "This resets only the Manager administrator password and active browser sessions."
    echo "Newsletter configuration, schedules, output, and delivery state are preserved."
    confirm "Reset Manager access and restart the Docker Desktop service?" || exit 0
    compose_cmd exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
      /opt/tautweekly/bin/tautweekly-manager access-recover --data-dir /data/manager \
      --tautweekly-root /opt/tautweekly --listen 0.0.0.0:8080 --runtime-mode mac \
      --package-kind "${TAUTWEEKLY_PACKAGE_KIND:-mac-docker}" --confirm
    compose_cmd restart tautweekly
    echo "Run ./tautweekly.sh manager-bootstrap to retrieve the new one-time pairing token."
    ;;
  remote-access-login|remote-access-authorize)
    compose_cmd exec tautweekly /opt/tautweekly/bin/tautweekly-funnel login
    ;;
  remote-access-disable) remote_cleanup ;;
  schedule-status) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Schedule-Control.ps1 -Action Status ;;
  schedule-enable)
    confirm "Enable the configured automatic weekly send?" || exit 0
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Schedule-Control.ps1 -Action Enable
    ;;
  schedule-disable) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Schedule-Control.ps1 -Action Disable ;;
  schedule-reset)
    echo "This clears today's automatic-attempt guard. A later scheduler poll may send again today."
    confirm "Clear the guard?" || exit 0
    compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Schedule-Control.ps1 -Action ResetToday
    ;;
  backup)
    stamp="$(date +%Y%m%d-%H%M%S)"
    tar -czf "tautweekly-data-backup-$stamp.tar.gz" data
    echo "Created tautweekly-data-backup-$stamp.tar.gz"
    ;;
  check-update) package_update check ;;
  update) remote_cleanup; package_update apply ;;
  open-manager|open-preview)
    base_url="http://localhost:8787"
    if [[ -f .env ]]; then
      configured="$(awk -F= '$1=="PREVIEW_BASE_URL"{print substr($0,index($0,"=")+1)}' .env | tail -1)"
      [[ -z "$configured" ]] || base_url="$configured"
    fi
    open "$base_url/"
    ;;
  help|*)
    cat <<'EOF'
TautWeekly for Plex Mac Portable commands

  ./tautweekly.sh install
  ./tautweekly.sh open-manager
  ./tautweekly.sh manager-bootstrap
  ./tautweekly.sh manager-reset-access
  ./tautweekly.sh remote-access-login
  ./tautweekly.sh remote-access-disable
  ./tautweekly.sh setup                 # expert/recovery fallback
  ./tautweekly.sh verify                # expert/recovery fallback
  ./tautweekly.sh cache-status
  ./tautweekly.sh cache-refresh
  ./tautweekly.sh list-users
  ./tautweekly.sh exclude-users
  ./tautweekly.sh list-libraries
  ./tautweekly.sh manage-libraries
  ./tautweekly.sh preview USER_ID
  ./tautweekly.sh preview-all USER_ID
  ./tautweekly.sh send-test USER_ID
  ./tautweekly.sh send-test-all USER_ID
  ./tautweekly.sh welcome USER_ID
  ./tautweekly.sh send-all
  ./tautweekly.sh roster
  ./tautweekly.sh schedule-status
  ./tautweekly.sh schedule-enable
  ./tautweekly.sh schedule-disable
  ./tautweekly.sh schedule-reset
  ./tautweekly.sh logs
  ./tautweekly.sh status
  ./tautweekly.sh start
  ./tautweekly.sh stop
  ./tautweekly.sh restart
  ./tautweekly.sh backup
  ./tautweekly.sh check-update
  ./tautweekly.sh update
  ./tautweekly.sh shell

USER_ID is the numeric value shown by list-users. Omit it only in an
interactive terminal when you want the wrapper to prompt for it.
EOF
    ;;
esac
