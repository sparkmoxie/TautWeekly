#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
clear
printf '\033[1;33mPLEXWEEKLY MAC PORTABLE INSTALLER\033[0m\n\n'
chmod +x mac-install.sh plexweekly.sh INSTALL-MAC.command 2>/dev/null || true
./mac-install.sh
status=$?
printf '\n'
read -r -n 1 -s -p "Press any key to close this window..."
printf '\n'
exit "$status"
