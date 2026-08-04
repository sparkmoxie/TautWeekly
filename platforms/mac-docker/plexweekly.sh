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
  restart) compose_cmd restart plexweekly ;;
  status) compose_cmd ps ;;
  logs) compose_cmd logs -f --tail=200 plexweekly ;;
  shell) compose_cmd exec plexweekly bash ;;
  setup) compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Setup-First.ps1 ;;
  verify) compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Verify-Setup.ps1 ;;
  list-users) compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh ListUsers ;;
  preview)
    user="$(prompt_user "${1:-}")"
    compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh Preview "$user"
    ;;
  preview-all)
    user="$(prompt_user "${1:-}")"
    compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh PreviewAll "$user"
    ;;
  send-test)
    user="$(prompt_user "${1:-}")"
    confirm "Send one test email to TestEmail using $user?" || exit 0
    compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh SendTest "$user"
    ;;
  send-test-all)
    user="$(prompt_user "${1:-}")"
    confirm "Send all six regression emails to TestEmail using $user?" || exit 0
    compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh SendTestAll "$user"
    ;;
  welcome)
    user="$(prompt_user "${1:-}")"
    confirm "Send the real one-off welcome to the selected Plex user's email?" || exit 0
    compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh SendWelcome "$user" --confirm-welcome
    ;;
  send-all)
    echo "WARNING: This sends one real newsletter to every eligible Plex user."
    confirm "Have you reviewed a current TestEmail and do you want to continue?" || exit 0
    compose_cmd exec plexweekly /opt/plexweekly/bin/run-mode.sh SendAll --confirm-send-all
    ;;
  roster) compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/View-Access-Roster.ps1 ;;
  repair-assets) compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Repair-Assets.ps1 ;;
  schedule-status) compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Schedule-Control.ps1 -Action Status ;;
  schedule-enable)
    confirm "Enable the configured automatic weekly send?" || exit 0
    compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Schedule-Control.ps1 -Action Enable
    ;;
  schedule-disable) compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Schedule-Control.ps1 -Action Disable ;;
  schedule-reset)
    echo "This clears today's automatic-attempt guard. A later scheduler poll may send again today."
    confirm "Clear the guard?" || exit 0
    compose_cmd exec plexweekly pwsh -NoLogo -NoProfile -File /opt/plexweekly/Schedule-Control.ps1 -Action ResetToday
    ;;
  backup)
    stamp="$(date +%Y%m%d-%H%M%S)"
    tar -czf "plexweekly-data-backup-$stamp.tar.gz" data
    echo "Created plexweekly-data-backup-$stamp.tar.gz"
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
PlexWeekly Mac Portable commands

  ./plexweekly.sh install
  ./plexweekly.sh open-preview
  ./plexweekly.sh verify
  ./plexweekly.sh list-users
  ./plexweekly.sh preview [user]
  ./plexweekly.sh preview-all [user]
  ./plexweekly.sh send-test [user]
  ./plexweekly.sh send-test-all [user]
  ./plexweekly.sh welcome [user]
  ./plexweekly.sh send-all
  ./plexweekly.sh roster
  ./plexweekly.sh schedule-status
  ./plexweekly.sh schedule-enable
  ./plexweekly.sh schedule-disable
  ./plexweekly.sh schedule-reset
  ./plexweekly.sh logs
  ./plexweekly.sh status
  ./plexweekly.sh restart
  ./plexweekly.sh backup
  ./plexweekly.sh update
  ./plexweekly.sh shell
EOF
    ;;
esac
