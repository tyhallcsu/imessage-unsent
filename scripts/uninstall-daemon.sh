#!/usr/bin/env bash
# Uninstall the imessage-unsent user LaunchAgent.

set -euo pipefail

PLIST_DEST="$HOME/Library/LaunchAgents/com.imu.watcher.plist"
BIN_DEST="$HOME/Library/Application Support/imessage-unsent/bin/imu-watcher"

launchctl bootout "gui/$UID" "$PLIST_DEST" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"
rm -f "$BIN_DEST"

echo "Uninstalled com.imu.watcher."
