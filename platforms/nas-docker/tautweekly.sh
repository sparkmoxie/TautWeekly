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
  export TAUTWEEKLY_PACKAGE_KIND=nas-docker
  export TAUTWEEKLY_PACKAGE_ROOT="$package_root"
  exec bash "$updater" "$@"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  install) exec ./qnap-install.sh ;;
  build)
    echo "The release Compose file pulls the published image and has no local build definition." >&2
    echo "Source builds use the repository root: docker build -f platforms/nas-docker/Dockerfile ." >&2
    exit 64
    ;;
  up|start) compose_cmd up -d ;;
  down|stop) compose_cmd down ;;
  restart) compose_cmd restart tautweekly ;;
  status) compose_cmd ps ;;
  logs) compose_cmd logs -f --tail=200 tautweekly ;;
  shell) compose_cmd exec tautweekly /opt/tautweekly/bin/run-as-user.sh bash ;;
  setup) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Setup-First.ps1 ;;
  verify) compose_cmd exec tautweekly /opt/tautweekly/bin/run-script.sh Verify-Setup.ps1 ;;
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
    confirm "Reset Manager access and restart the container?" || exit 0
    compose_cmd exec -T tautweekly /opt/tautweekly/bin/run-as-user.sh \
      /opt/tautweekly/bin/tautweekly-manager access-recover --data-dir /data/manager --confirm
    compose_cmd restart tautweekly
    echo "Run ./tautweekly.sh manager-bootstrap to retrieve the new one-time pairing token."
    ;;
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
  update) package_update apply ;;
  help|*)
    cat <<'EOF'
TautWeekly for Plex NAS Portable commands

  ./tautweekly.sh install
  ./tautweekly.sh setup
  ./tautweekly.sh verify
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
  ./tautweekly.sh repair-assets
  ./tautweekly.sh manager-bootstrap
  ./tautweekly.sh manager-reset-access
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
