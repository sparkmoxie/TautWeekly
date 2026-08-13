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
if [[ ! -f "$app_source/TautWeekly.ps1" ]]; then
  app_source="$source_root/../nas-docker/app"
fi
if [[ ! -f "$source_root/check-release.sh" ]]; then
  echo "Release checker not found. Use an official Linux release archive or a complete repository checkout." >&2
  exit 66
fi
if [[ ! -f "$app_source/TautWeekly.ps1" ]]; then
  echo "Application payload not found. Use an official Linux release archive or a complete repository checkout." >&2
  exit 66
fi

for command_name in curl flock pwsh python3 systemctl runuser install tar; do
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

if [[ -f "$source_root/RELEASE-METADATA.txt" ]]; then
  install -m 0644 -o root -g root "$source_root/RELEASE-METADATA.txt" /opt/tautweekly/RELEASE-METADATA.txt
else
  printf '%s\n' 'TautWeekly for Plex development checkout' 'Repository version: dev' > /opt/tautweekly/RELEASE-METADATA.txt
  chmod 0644 /opt/tautweekly/RELEASE-METADATA.txt
fi

install -m 0755 -o root -g root "$source_root/tautweekly" /usr/local/bin/tautweekly
install -m 0755 -o root -g root "$source_root/check-release.sh" /usr/local/libexec/tautweekly-check-release
install -m 0644 -o root -g root "$source_root/systemd/tautweekly.service" /etc/systemd/system/tautweekly.service
if [[ ! -f /etc/tautweekly/tautweekly.env ]]; then
  install -m 0600 -o root -g root "$source_root/tautweekly.env.example" /etc/tautweekly/tautweekly.env
  echo "Created /etc/tautweekly/tautweekly.env with localhost-only preview defaults."
else
  echo "Preserved existing /etc/tautweekly/tautweekly.env."
fi
if [[ ! -f /var/lib/tautweekly/config.example.json ]]; then
  install -m 0600 -o tautweekly -g tautweekly "$app_source/config.example.json" /var/lib/tautweekly/config.example.json
fi

systemctl daemon-reload
systemctl enable tautweekly.service >/dev/null
$was_active && systemctl start tautweekly.service

installed_version="$(sed -n 's/^Repository version:[[:space:]]*//p' /opt/tautweekly/RELEASE-METADATA.txt | head -n 1)"
if [[ -z "$installed_version" ]]; then
  echo "Installed release metadata could not be verified." >&2
  exit 70
fi
if [[ "$was_active" == true ]]; then
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
  sudo tautweekly setup
  Complete the metadata-readiness sequence above after setup, then:
  sudo tautweekly verify
  sudo tautweekly preview-all USER_ID
  sudo tautweekly send-test-all USER_ID

The service is enabled but automatic sending remains disabled until you opt in.
EOF
