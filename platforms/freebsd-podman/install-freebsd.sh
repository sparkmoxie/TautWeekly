#!/bin/sh
set -eu

# Repair only the exact unresolved default shipped in the old FreeBSD archive.
# Keep the token split so release-time token expansion cannot change this match.
repair_legacy_image_default() (
  env_path="$1"
  metadata_path="$2"
  legacy_token='__TAUTWEEKLY_RELEASE_''VERSION__'
  legacy_image="ghcr.io/sparkmoxie/tautweekly:$legacy_token"
  [ -f "$env_path" ] || return 0
  grep -Fqx "TAUTWEEKLY_IMAGE=$legacy_image" "$env_path" || return 0
  if [ ! -r "$metadata_path" ]; then
    echo "Cannot repair the legacy image default without release metadata. Use an official release archive." >&2
    exit 65
  fi
  if [ "$(grep -c '^Repository version:' "$metadata_path")" -ne 1 ]; then
    echo 'Cannot repair the legacy image default: release metadata is ambiguous.' >&2
    exit 65
  fi
  version="$(sed -n 's/^Repository version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*$/\1/p' "$metadata_path")"
  case "$version" in ''|*[!0-9.]*) echo 'Cannot repair the legacy image default: release metadata is malformed.' >&2; exit 65 ;; esac
  if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
    echo 'Cannot repair the legacy image default: release metadata is not a full stable version.' >&2
    exit 65
  fi
  temporary="$(mktemp "${env_path}.repair.XXXXXX")" || exit 70
  trap 'rm -f "$temporary"' EXIT
  sed "s|^TAUTWEEKLY_IMAGE=ghcr[.]io/sparkmoxie/tautweekly:$legacy_token\$|TAUTWEEKLY_IMAGE=ghcr.io/sparkmoxie/tautweekly:$version|" "$env_path" >"$temporary" || exit 70
  chmod 0600 "$temporary" || exit 70
  chown root:wheel "$temporary" || exit 70
  mv -f "$temporary" "$env_path" || exit 70
  echo "Repaired the legacy default image reference to release $version."
)

mode="${1:-install}"
if [ "$mode" != install ] && [ "$mode" != --upgrade-and-update ]; then
  echo "Usage: sudo ./install-freebsd.sh [--upgrade-and-update]" >&2
  exit 64
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must run as root. Use sudo or doas." >&2
  exit 77
fi
if [ "$(uname -s)" != "FreeBSD" ]; then
  echo "This package is only for FreeBSD. Linux users should use the native Linux or NAS/Docker package." >&2
  exit 69
fi
case "$(uname -m)" in
  amd64|x86_64) ;;
  *)
    echo "The initial FreeBSD Podman package supports amd64 hosts only." >&2
    exit 69
    ;;
esac

source_root="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_update_source="$source_root/package-update.sh"
if [ ! -f "$package_update_source" ]; then
  package_update_source="$source_root/../shared/package-update.sh"
fi
for file in "$source_root/tautweekly" "$source_root/rc.d/tautweekly" "$source_root/tautweekly.env.example" "$package_update_source"; do
  if [ ! -f "$file" ]; then
    echo "Incomplete package; missing $file" >&2
    exit 66
  fi
done

if ! command -v podman >/dev/null 2>&1; then
  echo "Installing Podman from the configured FreeBSD package repository..."
  pkg install -y podman
fi
if ! command -v bash >/dev/null 2>&1; then
  echo "Installing Bash for verified release-package updates..."
  pkg install -y bash
fi

sysrc linux_enable=YES >/dev/null
service linux status >/dev/null 2>&1 || service linux start
sysrc podman_enable=YES >/dev/null
service podman status >/dev/null 2>&1 || service podman start

if ! pw groupshow tautweekly >/dev/null 2>&1; then
  pw groupadd tautweekly -g 8787
fi
if ! pw usershow tautweekly >/dev/null 2>&1; then
  pw useradd tautweekly -u 8787 -g tautweekly -d /var/db/tautweekly -s /usr/sbin/nologin -c "TautWeekly for Plex service"
fi

install -d -m 0755 /usr/local/etc/tautweekly /usr/local/etc/rc.d /usr/local/sbin /usr/local/libexec /usr/local/share/tautweekly
install -d -m 0700 -o tautweekly -g tautweekly /var/db/tautweekly /var/db/tautweekly/backups
install -m 0755 "$source_root/tautweekly" /usr/local/sbin/tautweekly
install -m 0555 "$source_root/rc.d/tautweekly" /usr/local/etc/rc.d/tautweekly
install -m 0555 "$package_update_source" /usr/local/libexec/tautweekly-package-update
if [ -f "$source_root/RELEASE-METADATA.txt" ]; then
  install -m 0444 "$source_root/RELEASE-METADATA.txt" /usr/local/share/tautweekly/RELEASE-METADATA.txt
else
  printf '%s\n' 'TautWeekly for Plex development checkout' 'Repository version: dev' > /usr/local/share/tautweekly/RELEASE-METADATA.txt
  chmod 0444 /usr/local/share/tautweekly/RELEASE-METADATA.txt
fi
if [ ! -f /usr/local/etc/tautweekly/tautweekly.env ]; then
  install -m 0600 "$source_root/tautweekly.env.example" /usr/local/etc/tautweekly/tautweekly.env
  echo "Created /usr/local/etc/tautweekly/tautweekly.env with localhost-only Manager defaults."
else
  echo "Preserved existing /usr/local/etc/tautweekly/tautweekly.env."
fi

repair_legacy_image_default /usr/local/etc/tautweekly/tautweekly.env /usr/local/share/tautweekly/RELEASE-METADATA.txt

sysrc tautweekly_enable=YES >/dev/null
/usr/local/sbin/tautweekly update-image

cat <<'EOF'

TautWeekly for Plex FreeBSD Podman support is installed.
Private data: /var/db/tautweekly
Service settings: /usr/local/etc/tautweekly/tautweekly.env

Next:
  sudo tautweekly manager-bootstrap
  ssh -L 8787:127.0.0.1:8787 YOUR_FREEBSD_ADMIN@YOUR_FREEBSD_HOST
  Open http://127.0.0.1:8787/ and complete Config, Verify, Previews, and TestEmail.

The one-time pairing token is returned only by manager-bootstrap and is never
written to the installer or service logs. The service is enabled, but automatic
sending remains disabled until you opt in through the authenticated Manager.
EOF

if [ -n "${TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT:-}" ]; then
  work_root="$TAUTWEEKLY_PACKAGE_UPDATE_WORK_ROOT"
  case "$(basename "$work_root")" in
    tautweekly-package-update.*) [ ! -d "$work_root" ] || rm -rf "$work_root" ;;
    *) echo "Refusing to remove an unexpected package staging directory: $work_root" >&2 ;;
  esac
fi
