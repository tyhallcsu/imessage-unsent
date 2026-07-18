#!/usr/bin/env bash
# scripts/lib/snapshot.sh — Vector 0: freeze chat.db family for offline forensics.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_SNAPSHOT:-}" ]] && return
IMU_LIB_SNAPSHOT=1

set -uo pipefail

# imu_snapshot <work_dir>
#
# Quits Messages.app, then copies ~/Library/Messages/{chat.db,chat.db-wal,chat.db-shm}
# into <work_dir>. Prints the snapshot db path (chat.db) on stdout. Logs to stderr.
#
# Exit codes:
#   0 — chat.db present in the snapshot directory
#   1 — chat.db missing in destination (FDA likely not granted)
#
imu_snapshot() {
  local work_dir="${1:?usage: imu_snapshot <work_dir>}"
  local live_dir="${2:-$HOME/Library/Messages}"
  local name source destination

  mkdir -p "$work_dir"
  osascript -e 'quit app "Messages"' 2>/dev/null || true
  sleep 2

  for name in chat.db chat.db-wal chat.db-shm; do
    source="$live_dir/$name"
    destination="$work_dir/$name"
    if [[ -f "$source" ]]; then
      cp "$source" "$destination"
      # The snapshot is a full copy of chat.db (every message). Force it
      # owner-only regardless of the source mode or cp/umask interplay (#112).
      chmod 600 "$destination" 2>/dev/null || true
      printf "%s\n" "$destination"
    fi
  done

  [[ -f "$work_dir/chat.db" ]]
}
