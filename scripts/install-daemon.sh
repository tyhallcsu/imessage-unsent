#!/usr/bin/env bash
# Install the imessage-unsent user LaunchAgent.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_SRC="$ROOT/daemon/.build/release/imu-watcher"
BIN_DEST="$HOME/Library/Application Support/imessage-unsent/bin/imu-watcher"
SCRIPTS_DEST="$HOME/Library/Application Support/imessage-unsent/scripts"
PLIST_SRC="$ROOT/daemon/com.imu.watcher.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.imu.watcher.plist"
LOG_PATH="$HOME/Library/Logs/imessage-unsent/watcher.log"

swift build --package-path "$ROOT/daemon" -c release
mkdir -p "$(dirname "$BIN_DEST")" "$SCRIPTS_DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/imessage-unsent"
install -m 0755 "$BIN_SRC" "$BIN_DEST"
rm -rf "$SCRIPTS_DEST"
mkdir -p "$SCRIPTS_DEST"
cp -R "$ROOT/scripts/." "$SCRIPTS_DEST/"
chmod 0755 "$SCRIPTS_DEST/recover.sh"

python3 - "$PLIST_SRC" "$PLIST_DEST" "$BIN_DEST" "$LOG_PATH" <<'PY'
from pathlib import Path
import sys

source, destination, binary_path, log_path = map(Path, sys.argv[1:5])
text = source.read_text()
text = text.replace("__IMU_WATCHER_BIN__", str(binary_path))
text = text.replace("__IMU_LOG_PATH__", str(log_path))
destination.write_text(text)
PY

launchctl bootout "gui/$UID" "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DEST"
launchctl print "gui/$UID/com.imu.watcher" || true

cat <<'MSG'

Installed com.imu.watcher.
Grant Full Disk Access to this installed binary:
  ~/Library/Application Support/imessage-unsent/bin/imu-watcher

Recovery scripts installed to:
  ~/Library/Application Support/imessage-unsent/scripts

The first recovered message may trigger a macOS notification permission prompt.

System Settings > Privacy & Security > Full Disk Access
MSG
