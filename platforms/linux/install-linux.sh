#!/usr/bin/env bash
set -euo pipefail

mode="${1:-install}"
if [[ "$mode" != "install" && "$mode" != "--upgrade" ]]; then
  echo "Usage: sudo ./install-linux.sh [--upgrade]" >&2
  exit 64
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "This installer must run as root. Use: sudo ./install-linux.sh" >&2
  exit 77
fi
if [[ ! -d /run/systemd/system ]]; then
  echo "systemd is required for the native Linux package." >&2
  echo "Use the NAS/Docker package on Linux systems without systemd." >&2
  exit 69
fi

source_root="$(cd "$(dirname "$0")" && pwd)"
app_source="$source_root/app"
package_update_source="$source_root/package-update.sh"
if [[ ! -f "$app_source/TautWeekly.ps1" ]]; then
  app_source="$source_root/../nas-docker/app"
fi
if [[ ! -f "$package_update_source" ]]; then
  package_update_source="$source_root/../shared/package-update.sh"
fi
if [[ ! -f "$source_root/check-release.sh" ]]; then
  echo "Release checker not found. Use an official Linux release archive or a complete repository checkout." >&2
  exit 66
fi
if [[ ! -f "$package_update_source" ]]; then
  echo "Package updater not found. Use an official Linux release archive or a complete repository checkout." >&2
  exit 66
fi
if [[ ! -f "$app_source/TautWeekly.ps1" ]]; then
  echo "Application payload not found. Use an official Linux release archive or a complete repository checkout." >&2
  exit 66
fi

case "$(uname -m)" in
  x86_64|amd64) manager_arch=amd64 ;;
  aarch64|arm64) manager_arch=arm64 ;;
  *)
    echo "The native Linux Manager supports only 64-bit x86_64/amd64 and aarch64/arm64 hosts." >&2
    exit 69
    ;;
esac
manager_source="$source_root/manager/tautweekly-manager-linux-$manager_arch"
if [[ ! -f "$manager_source" ]]; then
  echo "Linux $manager_arch Manager payload not found. Use an official Linux release archive." >&2
  exit 66
fi

for command_name in convert curl flock identify pwsh python3 systemctl runuser install tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Required command not found: $command_name" >&2
    exit 69
  }
done

pwsh_version="$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
pwsh_major="${pwsh_version%%.*}"
pwsh_minor="${pwsh_version#*.}"
pwsh_minor="${pwsh_minor%%.*}"
if (( pwsh_major < 7 || (pwsh_major == 7 && pwsh_minor < 2) )); then
  echo "PowerShell 7.2 or newer is required; found $pwsh_version." >&2
  echo "Install a supported PowerShell release from Microsoft before continuing." >&2
  exit 69
fi

if ! getent group tautweekly >/dev/null; then
  groupadd --system tautweekly
fi
if ! id -u tautweekly >/dev/null 2>&1; then
  useradd --system --gid tautweekly --home-dir /var/lib/tautweekly --shell /usr/sbin/nologin tautweekly
fi

install -d -m 0755 -o root -g root /opt/tautweekly /etc/tautweekly
install -d -m 0755 -o root -g root /usr/local/libexec
install -d -m 0700 -o tautweekly -g tautweekly /var/lib/tautweekly
install -d -m 0700 -o tautweekly -g tautweekly /var/lib/tautweekly/backups

# Metadata and the executable must identify the same candidate before stopping anything.
expected_version=dev
if [[ -f "$source_root/RELEASE-METADATA.txt" ]]; then
  expected_version="$(sed -n 's/^Repository version:[[:space:]]*//p' "$source_root/RELEASE-METADATA.txt" | head -n 1)"
fi
if [[ ! "$expected_version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] ||
   [[ "$("$manager_source" version)" != "TautWeekly Manager $expected_version" ]]; then
  echo "Candidate Manager and repository release metadata do not agree." >&2
  exit 65
fi
fresh_install=true
[[ ! -f /opt/tautweekly/TautWeekly.ps1 ]] || fresh_install=false
if [[ "$fresh_install" == false && "$mode" != --upgrade ]]; then
  echo "An installation already exists; use --upgrade so the running service is stopped safely." >&2
  exit 64
fi
[[ ! -L /opt/tautweekly ]] || { echo "Refusing a symlinked application directory." >&2; exit 65; }

# Installer admission is separate from the renderer lock. Never hold the latter
# while stopping a supervisor whose shutdown waits for that same lock to clear.
exec 7> /etc/tautweekly/.upgrade.lock
chmod 0600 /etc/tautweekly/.upgrade.lock
flock -n 7 || { echo "Another TautWeekly installer is running." >&2; exit 75; }
if [[ ! -e /var/lib/tautweekly/.tautweekly-operation.lock ]]; then
  runuser -u tautweekly -- touch /var/lib/tautweekly/.tautweekly-operation.lock
fi
exec 9< /var/lib/tautweekly/.tautweekly-operation.lock
if ! flock -n 9; then
  echo "Another TautWeekly operation is running; the upgrade was not started." >&2
  exit 75
fi
flock -u 9

was_active=false
was_enabled=false
systemctl is-active --quiet tautweekly.service && was_active=true
systemctl is-enabled --quiet tautweekly.service && was_enabled=true
mutation_started=false
service_touched=false
completed=false
backup=""
host_files=(
  /usr/local/bin/tautweekly /usr/local/libexec/tautweekly-check-release
  /usr/local/libexec/tautweekly-package-update /etc/systemd/system/tautweekly.service
  /etc/systemd/system/tautweekly-remote-access.socket
  /etc/systemd/system/tautweekly-remote-access@.service
  /etc/tautweekly/tautweekly.env
)

restore_previous_installation() {
  local index target
  flock -u 9
  if [[ "$service_touched" == true ]]; then
    systemctl stop tautweekly.service || return 1
  fi
  if [[ "$mutation_started" == true ]]; then
    flock -n 9 || return 1
    # Literal, checked package directory only; never remove the private runtime root.
    [[ ! -L /opt/tautweekly && -d /opt/tautweekly ]] || return 1
    rm -rf -- /opt/tautweekly || return 1
    if [[ "$fresh_install" == false ]]; then
      tar -xzf "$backup/program.tar.gz" -C /opt || return 1
    else
      install -d -m 0755 -o root -g root /opt/tautweekly || return 1
    fi
    for index in "${!host_files[@]}"; do
      target="${host_files[$index]}"
      if [[ -e "$backup/host-$index" || -L "$backup/host-$index" ]]; then
        cp -a -- "$backup/host-$index" "$target" || return 1
      else
        rm -f -- "$target" || return 1
      fi
    done
    flock -u 9
    systemctl daemon-reload || return 1
    if [[ "$was_enabled" == true ]]; then
      systemctl enable tautweekly.service >/dev/null || return 1
    else
      systemctl disable tautweekly.service >/dev/null || return 1
    fi
  fi
  if [[ "$was_active" == true && "$service_touched" == true ]]; then
    systemctl start tautweekly.service || return 1
    systemctl is-active --quiet tautweekly.service || return 1
  fi
}
finish_installation() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$completed" != true && ( "$service_touched" == true || "$mutation_started" == true ) ]]; then
    echo "Installation failed; restoring the previous program, host files, and service state." >&2
    if restore_previous_installation; then
      echo "Previous installation and service state restored." >&2
    else
      echo "Automatic restoration needs administrator attention. Root-owned backup: $backup" >&2
    fi
  fi
  flock -u 9 || true
  if [[ "$status" -eq 0 && "$completed" != true ]]; then status=70; fi
  exit "$status"
}
trap finish_installation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# This backup is deliberately outside service-owned /var/lib: root must never
# restore executable code or systemd units from a service-writable snapshot.
install -d -m 0700 -o root -g root /var/backups/tautweekly
backup="$(mktemp -d /var/backups/tautweekly/program-$(date +%Y%m%d-%H%M%S).XXXXXX)"
chmod 0700 "$backup"
if [[ "$fresh_install" == false ]]; then
  tar -czf "$backup/program.tar.gz" -C /opt tautweekly
fi
for index in "${!host_files[@]}"; do
  target="${host_files[$index]}"
  if [[ -e "$target" || -L "$target" ]]; then cp -a -- "$target" "$backup/host-$index"; fi
done
echo "Root-owned rollback snapshot: $backup"
if [[ "$was_active" == true ]]; then
  service_touched=true
  systemctl stop tautweekly.service
fi
# A terminal operation can win the stop/reacquire race. Refuse before mutation
# and restore the service instead of installing over an active operation.
if ! flock -n 9; then
  echo "Another TautWeekly operation started during shutdown; no program files were changed." >&2
  exit 75
fi
mutation_started=true
cp -a "$app_source/." /opt/tautweekly/
chown -R root:root /opt/tautweekly
find /opt/tautweekly -type d -exec chmod 0755 {} +
find /opt/tautweekly -type f -exec chmod 0644 {} +
chmod 0755 /opt/tautweekly/*.sh /opt/tautweekly/bin/*.sh
install -m 0755 -o root -g root "$manager_source" /opt/tautweekly/bin/tautweekly-manager

if [[ -f "$source_root/RELEASE-METADATA.txt" ]]; then
  install -m 0644 -o root -g root "$source_root/RELEASE-METADATA.txt" /opt/tautweekly/RELEASE-METADATA.txt
else
  printf '%s\n' 'TautWeekly for Plex development checkout' 'Repository version: dev' > /opt/tautweekly/RELEASE-METADATA.txt
  chmod 0644 /opt/tautweekly/RELEASE-METADATA.txt
fi
install -m 0755 -o root -g root "$source_root/tautweekly" /usr/local/bin/tautweekly
install -m 0755 -o root -g root "$source_root/check-release.sh" /usr/local/libexec/tautweekly-check-release
install -m 0755 -o root -g root "$package_update_source" /usr/local/libexec/tautweekly-package-update
install -m 0644 -o root -g root "$source_root/systemd/tautweekly.service" /etc/systemd/system/tautweekly.service
install -m 0644 -o root -g root "$source_root/systemd/tautweekly-remote-access.socket" /etc/systemd/system/tautweekly-remote-access.socket
install -m 0644 -o root -g root "$source_root/systemd/tautweekly-remote-access@.service" /etc/systemd/system/tautweekly-remote-access@.service
if [[ ! -f /etc/tautweekly/tautweekly.env ]]; then
  install -m 0600 -o root -g root "$source_root/tautweekly.env.example" /etc/tautweekly/tautweekly.env
  echo "Created /etc/tautweekly/tautweekly.env with localhost-only Manager defaults."
else
  echo "Preserved existing /etc/tautweekly/tautweekly.env."
fi
if [[ ! -f /var/lib/tautweekly/config.example.json ]]; then
  install -m 0600 -o tautweekly -g tautweekly "$app_source/config.example.json" /var/lib/tautweekly/config.example.json
fi
# Apply bundle transitions as the service account; private runtime files remain theirs.
runuser -u tautweekly -- python3 /opt/tautweekly/refresh-assets.py --data-root /var/lib/tautweekly
installed_version="$(sed -n 's/^Repository version:[[:space:]]*//p' /opt/tautweekly/RELEASE-METADATA.txt | head -n 1)"
[[ "$installed_version" == "$expected_version" ]] || { echo "Installed release metadata differs from the candidate." >&2; exit 70; }
[[ "$(/opt/tautweekly/bin/tautweekly-manager version)" == "TautWeekly Manager $expected_version" ]] || { echo "Installed Manager version differs from the candidate." >&2; exit 70; }
systemctl daemon-reload
if [[ "$fresh_install" == true ]]; then systemctl enable tautweekly.service >/dev/null; fi
# The runtime must be able to acquire its lock before the supervisor is started.
flock -u 9
if [[ "$fresh_install" == true || "$was_active" == true ]]; then
  service_touched=true
  started_epoch="$(date +%s)"
  systemctl start tautweekly.service
  manager_listen="$( ( source /etc/tautweekly/tautweekly.env; printf '%s' "${TAUTWEEKLY_MANAGER_LISTEN:-127.0.0.1:8788}" ) )"
  ready=false
  for _ in {1..20}; do
    if systemctl is-active --quiet tautweekly.service &&
       python3 - "$started_epoch" "$manager_listen" "$(systemctl show --property=MainPID --value tautweekly.service)" <<'PY'
import datetime, json, os, pathlib, sys, urllib.request
try:
    started, listen, supervisor = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    root = pathlib.Path('/var/lib/tautweekly')
    service = json.loads((root / 'service-heartbeat.json').read_text(encoding='utf-8-sig'))
    scheduler = json.loads((root / 'scheduler-heartbeat.json').read_text(encoding='utf-8-sig'))
    for heartbeat in (service, scheduler):
        observed = datetime.datetime.fromisoformat(heartbeat['Utc'].replace('Z', '+00:00')).timestamp()
        if not (started - 1 <= observed <= now + 5 and now - observed <= 90):
            raise ValueError("heartbeat timestamp")
    manager = int(service['ManagerProcessId'])
    scheduler_pid = int(service['SchedulerProcessId'])
    if supervisor <= 0 or int(service['ProcessId']) != supervisor:
        raise ValueError("supervisor identity")
    if scheduler_pid <= 0 or int(scheduler['ProcessId']) != scheduler_pid:
        raise ValueError("scheduler identity")
    for child in (manager, scheduler_pid):
        if child <= 0: raise ValueError("child identity")
        status = pathlib.Path(f'/proc/{child}/status').read_text()
        if f'PPid:\t{supervisor}\n' not in status: raise ValueError("parent identity")
    if not os.path.samefile(f'/proc/{manager}/exe', '/opt/tautweekly/bin/tautweekly-manager'):
        raise ValueError("Manager executable")
    host, port = listen.rsplit(':', 1)
    if not (host and port.isdigit() and 0 < int(port) <= 65535): raise ValueError("listener")
    if host in ('0.0.0.0', '::', '[::]'): host = '127.0.0.1'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f'http://{host}:{port}/health/live', timeout=2) as response:
        if response.status != 200 or json.load(response)['status'] != 'alive': raise ValueError("liveness")
except Exception:
    sys.exit(1)
PY
    then
      ready=true
      break
    fi
    sleep 2
  done
  if [[ "$ready" != true ]]; then
    echo "The expected Manager and scheduler did not become healthy; reverting the installation." >&2
    exit 70
  fi
fi
completed=true

cat <<EOF

TautWeekly for Plex native Linux files are installed.
PowerShell: $pwsh_version
Application: /opt/tautweekly
Repository version: $installed_version
Private data: /var/lib/tautweekly

Metadata readiness before Verify, Preview, or TestEmail:
  1. Confirm each included Plex Movie library's Advanced > Ratings Source.
  2. Run Plex Refresh All Metadata for every included movie/TV library and wait.
  3. In Tautulli, open each same Library > Media Info > Refresh media info and wait.
Repeat this after first install, a Plex agent/source change, or a ratings/artwork
recovery update when metadata may be stale. A routine update does not require a
full refresh when current metadata already renders correctly.

Next:
  1. From your workstation, open a protected tunnel:
       ssh -L 8788:127.0.0.1:8788 YOUR_LINUX_ADMIN@THIS_HOST
  2. On the Linux host, retrieve the one-time pairing token explicitly:
       sudo tautweekly manager-bootstrap
  3. Open http://127.0.0.1:8788, pair, create the administrator password,
     and complete guided Setup in the Manager.
  4. Complete the metadata-readiness sequence above, then use the Manager to
     verify, preview all six states, send TestEmail, and enable the schedule.

The authenticated Manager service is enabled. Automatic sending remains disabled
until you explicitly enable it in the Manager. CLI commands remain available as
documented recovery and expert fallbacks.

Optional public Tailscale Funnel remains disabled. After the official Tailscale
Linux package is installed, running, and signed in by the host administrator,
authorize only TautWeekly's fixed one-shot adapter:
  sudo tautweekly remote-access-authorize
Create and enable a unique Manager password, then use Settings > Tailscale
Funnel. Manager stays on loopback; the adapter accepts only the exact package
target and typed operations. A remote viewer needs no Tailscale client, so
retain local recovery and treat Internet login attempts as a remaining risk.
EOF

if [[ -n "${TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT:-}" ]]; then
  work_root="$TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT"
  if [[ -d "$work_root" && "$(basename "$work_root")" == tautweekly-package-update.* &&
        "$(cd "$(dirname "$work_root")" && pwd -P)" == "$(cd "${TMPDIR:-/tmp}" && pwd -P)" ]]; then
    rm -rf "$work_root"
  else
    echo "Refusing to remove an unexpected package staging directory: $work_root" >&2
  fi
fi
