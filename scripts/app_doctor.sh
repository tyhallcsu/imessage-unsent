#!/usr/bin/env bash
#
# app_doctor.sh — terminal/headless subset of the GUI's App Doctor checks.
#
# Useful when the menu bar app itself can't launch (FDA prompt loop, Gatekeeper
# block) or during SSH troubleshooting. Output format matches the GUI's
# Diagnostics report so a user can paste either source into a GitHub issue.
#
# Honors $HOME so callers (and tests) can point it at a fake install tree:
#   HOME=/tmp/fake-home bash scripts/app_doctor.sh
#
# This script intentionally never reads chat.db, never opens archive files,
# and never prints message content. It only touches metadata and existence.

set -euo pipefail

HOME_DIR="${HOME:?HOME is unset; cannot locate user install}"
APP_SUPPORT="$HOME_DIR/Library/Application Support/imessage-unsent"
DAEMON_BINARY="$APP_SUPPORT/bin/imu-watcher"
LAUNCH_AGENT_PLIST="$HOME_DIR/Library/LaunchAgents/com.imu.watcher.plist"
RECOVERY_SCRIPT="$APP_SUPPORT/scripts/recover.sh"
SOCKET_FILE="$APP_SUPPORT/daemon.sock"
LOG_FILE="$HOME_DIR/Library/Logs/imessage-unsent/watcher.log"
ARCHIVES_DIR="$APP_SUPPORT/archives"
CONFIG_FILE="$HOME_DIR/.config/imessage-unsent/config.toml"
CHAT_DB="$HOME_DIR/Library/Messages/chat.db"
SERVICE_TARGET="gui/$(id -u)/com.imu.watcher"

emit() {
  local severity="$1" id="$2" title="$3" summary="$4" remediation="${5:-}"
  printf '[%s] %s — %s\n' "$severity" "$id" "$title"
  printf '       %s\n' "$summary"
  if [[ -n "$remediation" ]]; then
    printf '       Remediation: %s\n' "$remediation"
  fi
  printf '\n'
}

# Header
printf 'imessage-unsent diagnostics — %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf 'Source: scripts/app_doctor.sh (subset of GUI App Doctor — for full coverage open the menu bar app → Health Check…)\n'
printf 'HOME: %s\n\n' "$HOME_DIR"

# --- Daemon binary ---
if [[ -x "$DAEMON_BINARY" ]]; then
  emit PASS daemon.binary "Daemon binary" "Installed and executable at $DAEMON_BINARY"
elif [[ -e "$DAEMON_BINARY" ]]; then
  emit WARN daemon.binary "Daemon binary" \
    "Present but not executable at $DAEMON_BINARY" \
    "Run 'chmod +x $DAEMON_BINARY' or reinstall via 'make daemon-install'."
else
  emit FAIL daemon.binary "Daemon binary" \
    "Missing at $DAEMON_BINARY" \
    "Run 'make daemon-install' from the repo to build and install the watcher binary."
fi

# --- LaunchAgent plist ---
if [[ -e "$LAUNCH_AGENT_PLIST" ]]; then
  emit PASS daemon.plist "LaunchAgent plist" "Installed at $LAUNCH_AGENT_PLIST"
else
  emit FAIL daemon.plist "LaunchAgent plist" \
    "Missing at $LAUNCH_AGENT_PLIST" \
    "Run 'make daemon-install' to install the plist and bootstrap the LaunchAgent."
fi

# --- launchctl loaded ---
launchctl_output=""
if [[ -x /bin/launchctl ]]; then
  launchctl_output="$(/bin/launchctl print "$SERVICE_TARGET" 2>&1 || true)"
fi
if [[ -z "$launchctl_output" ]]; then
  emit WARN daemon.launchctl "LaunchAgent loaded" \
    "/bin/launchctl is not available on this system" \
    "Skipping — only macOS installs ship launchctl."
elif grep -qi 'could not find service' <<<"$launchctl_output"; then
  emit FAIL daemon.launchctl "LaunchAgent loaded" \
    "launchd does not know about $SERVICE_TARGET" \
    "Run 'make daemon-install' or 'launchctl bootstrap gui/$(id -u) $LAUNCH_AGENT_PLIST'."
else
  state="$(awk -F'=' '
    /^[[:space:]]*state[[:space:]]*=/ {
      sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit
    }' <<<"$launchctl_output")"
  pid="$(awk -F'=' '
    /^[[:space:]]*pid[[:space:]]*=/ {
      sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit
    }' <<<"$launchctl_output")"
  exit_code="$(awk -F'=' '
    /^[[:space:]]*last exit code[[:space:]]*=/ {
      sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit
    }' <<<"$launchctl_output")"
  if [[ -z "$state" ]]; then
    emit WARN daemon.launchctl "LaunchAgent loaded" \
      "Could not parse 'launchctl print $SERVICE_TARGET' output" \
      "Run 'launchctl print $SERVICE_TARGET' in a terminal to see the full output."
  elif [[ "$state" == "running" ]]; then
    if [[ -n "$pid" ]]; then
      emit PASS daemon.launchctl "LaunchAgent loaded" "launchd reports 'running' (pid $pid)"
    else
      emit PASS daemon.launchctl "LaunchAgent loaded" "launchd reports 'running'"
    fi
  elif [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
    emit FAIL daemon.launchctl "LaunchAgent loaded" \
      "launchd reports '$state' — last exit code $exit_code" \
      "Try 'launchctl kickstart -k $SERVICE_TARGET'. If it keeps exiting, check $LOG_FILE."
  else
    emit WARN daemon.launchctl "LaunchAgent loaded" \
      "launchd reports '$state'" \
      "Try 'launchctl kickstart -k $SERVICE_TARGET'."
  fi
fi

# --- Recovery scripts ---
if [[ -e "$RECOVERY_SCRIPT" ]]; then
  emit PASS daemon.scripts "Recovery scripts" "Installed at $RECOVERY_SCRIPT"
else
  emit WARN daemon.scripts "Recovery scripts" \
    "recover.sh not found at $RECOVERY_SCRIPT" \
    "Run 'make daemon-install' to copy the recovery scripts into place."
fi

# --- Daemon control socket ---
if [[ -e "$SOCKET_FILE" ]]; then
  emit INFO socket.exists "Daemon control socket" "Present at $SOCKET_FILE"
else
  emit INFO socket.exists "Daemon control socket" \
    "Missing at $SOCKET_FILE — daemon may not be running"
fi

# --- Daemon log ---
if [[ -e "$LOG_FILE" ]]; then
  size="$(stat -f '%z' "$LOG_FILE" 2>/dev/null || stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"
  emit INFO daemon.log "Daemon log" "Present at $LOG_FILE ($size bytes)"
else
  emit INFO daemon.log "Daemon log" \
    "Missing at $LOG_FILE — daemon hasn't run yet, or log dir was wiped"
fi

# --- Full Disk Access (file-visibility heuristic) ---
messages_dir="$(dirname "$CHAT_DB")"
if [[ -e "$CHAT_DB" ]]; then
  emit PASS fda.granted "Full Disk Access" "chat.db is visible to this process"
elif [[ ! -e "$messages_dir" ]]; then
  emit WARN fda.granted "Full Disk Access" \
    "Inconclusive — $messages_dir is not visible from this shell" \
    "This shell may itself lack Full Disk Access. The daemon's log is authoritative."
else
  emit FAIL fda.granted "Full Disk Access" \
    "chat.db is not visible — Full Disk Access likely missing" \
    "Open System Settings → Privacy & Security → Full Disk Access and add 'imu-watcher' from $DAEMON_BINARY."
fi

# --- Config file ---
if [[ -e "$CONFIG_FILE" ]]; then
  emit PASS config.file "Config file" "Present at $CONFIG_FILE"
else
  emit INFO config.file "Config file" \
    "Missing at $CONFIG_FILE — daemon will use defaults"
fi

# --- Archive directory ---
if [[ -d "$ARCHIVES_DIR" ]]; then
  count="$(find "$ARCHIVES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    noun="entry"
  else
    noun="entries"
  fi
  emit INFO archive.dir "Archive directory" \
    "Present with $count $noun at $ARCHIVES_DIR"
else
  emit WARN archive.dir "Archive directory" \
    "Missing at $ARCHIVES_DIR" \
    "Run 'make daemon-install' to create it, or wait until the first recovery."
fi
