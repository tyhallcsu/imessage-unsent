#!/usr/bin/env bash
# Install the imessage-unsent user LaunchAgent.

set -euo pipefail
: "${HOME:?HOME must be set}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

# Two layouts (#151 / R-1):
#   release tarball — this script ships as install.sh NEXT TO a prebuilt
#     ./imu-watcher, ./com.imu.watcher.plist, and ./scripts/; installing must
#     use those and must NOT try to swift-build (there is no source tree).
#   repo checkout — build from source as before.
if [[ -x "$SELF_DIR/imu-watcher" && -f "$SELF_DIR/com.imu.watcher.plist" ]]; then
  BIN_SRC="$SELF_DIR/imu-watcher"
  PLIST_SRC="$SELF_DIR/com.imu.watcher.plist"
  SCRIPTS_SRC="$SELF_DIR/scripts"
  BUILD_FROM_SOURCE=0
else
  BIN_SRC="$ROOT/daemon/.build/release/imu-watcher"
  PLIST_SRC="$ROOT/daemon/com.imu.watcher.plist"
  SCRIPTS_SRC="$ROOT/scripts"
  BUILD_FROM_SOURCE=1
fi

BIN_DEST="$HOME/Library/Application Support/imessage-unsent/bin/imu-watcher"
SCRIPTS_DEST="$HOME/Library/Application Support/imessage-unsent/scripts"
PLIST_DEST="$HOME/Library/LaunchAgents/com.imu.watcher.plist"
LOG_PATH="$HOME/Library/Logs/imessage-unsent/watcher.log"

if [[ "$BUILD_FROM_SOURCE" == "1" ]]; then
  swift build --package-path "$ROOT/daemon" -c release
fi
mkdir -p "$(dirname "$BIN_DEST")" "$SCRIPTS_DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/imessage-unsent"
install -m 0755 "$BIN_SRC" "$BIN_DEST"
rm -rf "$SCRIPTS_DEST"
mkdir -p "$SCRIPTS_DEST"
cp -R "$SCRIPTS_SRC/." "$SCRIPTS_DEST/"
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

Notifications are delivered by the menu bar app, not the daemon — enable them
via iMessage Unsent's Settings > Notifications.

System Settings > Privacy & Security > Full Disk Access
MSG
