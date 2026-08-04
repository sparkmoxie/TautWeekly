#!/bin/sh
set -eu

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
for file in "$source_root/tautweekly" "$source_root/rc.d/tautweekly" "$source_root/tautweekly.env.example"; do
  if [ ! -f "$file" ]; then
    echo "Incomplete package; missing $file" >&2
    exit 66
  fi
done

if ! command -v podman >/dev/null 2>&1; then
  echo "Installing Podman from the configured FreeBSD package repository..."
  pkg install -y podman
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

install -d -m 0755 /usr/local/etc/tautweekly /usr/local/etc/rc.d /usr/local/sbin
install -d -m 0700 -o tautweekly -g tautweekly /var/db/tautweekly
install -m 0755 "$source_root/tautweekly" /usr/local/sbin/tautweekly
install -m 0555 "$source_root/rc.d/tautweekly" /usr/local/etc/rc.d/tautweekly
if [ ! -f /usr/local/etc/tautweekly/tautweekly.env ]; then
  install -m 0600 "$source_root/tautweekly.env.example" /usr/local/etc/tautweekly/tautweekly.env
  echo "Created /usr/local/etc/tautweekly/tautweekly.env with localhost-only preview defaults."
else
  echo "Preserved existing /usr/local/etc/tautweekly/tautweekly.env."
fi

image="$(awk -F= '/^TAUTWEEKLY_IMAGE=/{print substr($0,index($0,"=")+1); exit}' /usr/local/etc/tautweekly/tautweekly.env)"
if [ -z "$image" ]; then image="ghcr.io/sparkmoxie/tautweekly:latest"; fi
podman pull --os=linux "$image"
sysrc tautweekly_enable=YES >/dev/null
service tautweekly restart >/dev/null 2>&1 || service tautweekly start

cat <<'EOF'

TautWeekly for Plex FreeBSD Podman support is installed.
Private data: /var/db/tautweekly
Service settings: /usr/local/etc/tautweekly/tautweekly.env

Next:
  sudo tautweekly setup
  sudo tautweekly verify
  sudo tautweekly preview-all
  sudo tautweekly send-test-all

The service is enabled but automatic sending remains disabled until you opt in.
EOF
