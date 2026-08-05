#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

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

cmd="${1:-help}"; shift || true
case "$cmd" in
  install) exec ./mac-install.sh ;;
  build) compose_cmd build --pull ;;
  up|start) compose_cmd up -d ;;
  down|stop) compose_cmd down ;;
  restart) compose_cmd restart tautweekly ;;
  status) compose_cmd ps ;;
  logs) compose_cmd logs -f --tail=200 tautweekly ;;
  shell) compose_cmd exec tautweekly bash ;;
  setup) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Setup-First.ps1 ;;
  verify) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Verify-Setup.ps1 ;;
  list-users) compose_cmd exec tautweekly /opt/tautweekly/bin/run-mode.sh ListUsers ;;
  exclude-users|manage-exclusions) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-User-Exclusions.ps1 ;;
  list-libraries) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1 -ListOnly ;;
  libraries|manage-libraries) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Manage-Library-Selection.ps1 ;;
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
  roster) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/View-Access-Roster.ps1 ;;
  repair-assets) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Repair-Assets.ps1 ;;
  schedule-status) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Schedule-Control.ps1 -Action Status ;;
  schedule-enable)
    confirm "Enable the configured automatic weekly send?" || exit 0
    compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Schedule-Control.ps1 -Action Enable
    ;;
  schedule-disable) compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Schedule-Control.ps1 -Action Disable ;;
  schedule-reset)
    echo "This clears today's automatic-attempt guard. A later scheduler poll may send again today."
    confirm "Clear the guard?" || exit 0
    compose_cmd exec tautweekly pwsh -NoLogo -NoProfile -File /opt/tautweekly/Schedule-Control.ps1 -Action ResetToday
    ;;
  backup)
    stamp="$(date +%Y%m%d-%H%M%S)"
    tar -czf "tautweekly-data-backup-$stamp.tar.gz" data
    echo "Created tautweekly-data-backup-$stamp.tar.gz"
    ;;
  update)
    compose_cmd build --pull
    compose_cmd up -d
    ;;
  open-preview)
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
  ./tautweekly.sh setup
  ./tautweekly.sh open-preview
  ./tautweekly.sh verify
  ./tautweekly.sh list-users
  ./tautweekly.sh exclude-users
  ./tautweekly.sh list-libraries
  ./tautweekly.sh manage-libraries
  ./tautweekly.sh preview [user]
  ./tautweekly.sh preview-all [user]
  ./tautweekly.sh send-test [user]
  ./tautweekly.sh send-test-all [user]
  ./tautweekly.sh welcome [user]
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
  ./tautweekly.sh update
  ./tautweekly.sh shell
EOF
    ;;
esac
