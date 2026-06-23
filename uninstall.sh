#!/bin/bash
# Copyright 2026
# SPDX-License-Identifier: Apache-2.0
#
# Uninstaller for Printer Don't Die Please!!. Removes the agent, scripts, applet and
# alias. State/log files are left in place unless you pass --purge.
set -euo pipefail

SCRIPTS="$HOME/Library/Scripts"
LABEL="com.printer-keepalive.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -f "$PLIST"; ok "Removed launch agent"

rm -f "$SCRIPTS/printer-keepalive.sh" "$SCRIPTS/pkeep" \
      "$SCRIPTS/printer-keepalive.sh.bak" "$SCRIPTS/pkeep.bak"
rm -rf "$SCRIPTS/PrinterKeepaliveNotifier.app"
ok "Removed scripts and notifier app"

# remove the alias line (and its comment) from the shell rc
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$RC" ] || continue
    if grep -q 'alias pkeep=' "$RC"; then
        sed -i '' '/nozzle anti-clog control/d; /alias pkeep=/d' "$RC" 2>/dev/null || true
        ok "Removed alias from ${RC/#$HOME/~}"
    fi
done

if [ "$PURGE" = 1 ]; then
    rm -f "$SCRIPTS"/printer_keepalive.* "$SCRIPTS"/.printer_keepalive.* \
          "$HOME/Library/Logs/printer-keepalive.log" \
          "$HOME/Library/Logs/printer-keepalive.out.log" \
          "$HOME/Library/Logs/printer-keepalive.err.log"
    ok "Purged state and logs"
else
    printf '  \033[2m•\033[0m State/logs kept. Re-run with --purge to remove them.\n'
fi
echo "Done."
