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
rsync -a --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$ROOT/scripts/" "$SCRIPTS_DEST/"
chmod +x "$SCRIPTS_DEST/recover.sh" "$SCRIPTS_DEST"/lib/*.py
python3 - "$PLIST_SRC" "$PLIST_DEST" "$BIN_DEST" "$LOG_PATH" <<'PY'
from pathlib import Path
import sys

src, dest, bin_path, log_path = map(Path, sys.argv[1:5])
text = src.read_text()
text = text.replace("__IMU_WATCHER_BIN__", str(bin_path))
text = text.replace("__IMU_LOG_PATH__", str(log_path))
dest.write_text(text)
PY
launchctl bootout "gui/$UID" "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DEST"
launchctl print "gui/$UID/com.imu.watcher" || true

cat <<'MSG'

Installed com.imu.watcher.
Grant Full Disk Access to the installed imu-watcher binary in System Settings > Privacy & Security > Full Disk Access.
MSG
