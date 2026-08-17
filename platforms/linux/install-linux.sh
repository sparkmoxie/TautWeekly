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

was_active=false
fresh_install=true
[[ ! -f /opt/tautweekly/TautWeekly.ps1 ]] || fresh_install=false
if [[ "$mode" == "--upgrade" ]]; then
  exec 9>"/var/lib/tautweekly/.tautweekly-operation.lock"
  if ! flock -n 9; then
    echo "Another TautWeekly operation is running; the upgrade was not started." >&2
    exit 75
  fi
fi
if [[ "$mode" == "--upgrade" ]] && systemctl is-active --quiet tautweekly.service; then
  systemctl stop tautweekly.service
  was_active=true
fi
if [[ "$mode" == "--upgrade" && -f /opt/tautweekly/TautWeekly.ps1 ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="/var/lib/tautweekly/backups/program-$stamp.tar.gz"
  tar -czf "$backup" -C /opt tautweekly
  chown tautweekly:tautweekly "$backup"
  chmod 600 "$backup"
  echo "Backed up the previous application payload to $backup"
fi

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
if [[ ! -f /etc/tautweekly/tautweekly.env ]]; then
  install -m 0600 -o root -g root "$source_root/tautweekly.env.example" /etc/tautweekly/tautweekly.env
  echo "Created /etc/tautweekly/tautweekly.env with localhost-only Manager defaults."
else
  echo "Preserved existing /etc/tautweekly/tautweekly.env."
fi
if [[ ! -f /var/lib/tautweekly/config.example.json ]]; then
  install -m 0600 -o tautweekly -g tautweekly "$app_source/config.example.json" /var/lib/tautweekly/config.example.json
fi

systemctl daemon-reload
systemctl enable tautweekly.service >/dev/null
if [[ "$fresh_install" == true || "$was_active" == true ]]; then
  systemctl start tautweekly.service
fi

installed_version="$(sed -n 's/^Repository version:[[:space:]]*//p' /opt/tautweekly/RELEASE-METADATA.txt | head -n 1)"
if [[ -z "$installed_version" ]]; then
  echo "Installed release metadata could not be verified." >&2
  exit 70
fi
if [[ "$fresh_install" == true || "$was_active" == true ]]; then
  for _ in {1..15}; do
    systemctl is-active --quiet tautweekly.service && break
    sleep 2
  done
  if ! systemctl is-active --quiet tautweekly.service; then
    echo "The upgraded service did not become active. Restore the program backup shown above before retrying." >&2
    exit 70
  fi
fi

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
EOF

if [[ -n "${TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT:-}" ]]; then
  work_root="$TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT"
  if [[ -d "$work_root" && "$(basename "$work_root")" == tautweekly-package-update.* ]]; then
    rm -rf "$work_root"
  else
    echo "Refusing to remove an unexpected package staging directory: $work_root" >&2
  fi
fi
