#!/usr/bin/env bash
# scripts/lib/snapshot.sh — Vector 0: freeze chat.db family for offline forensics.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_SNAPSHOT:-}" ]] && return
IMU_LIB_SNAPSHOT=1

# imu_snapshot <work_dir>
#
# Quits Messages.app, then copies ~/Library/Messages/{chat.db,chat.db-wal,chat.db-shm}
# into <work_dir>. Prints the snapshot db path (chat.db) on stdout. Logs to stderr.
#
# Exit codes:
#   0 — snapshot complete, all three files present
#   1 — chat.db missing in destination (FDA likely not granted)
#
# TODO(#2): port the implementation from scripts/recover.sh, Step 0 (Freeze state).
#           Current logic uses `osascript -e 'quit app "Messages"'` + `cp` of all three files.
imu_snapshot() {
  local work_dir="${1:?usage: imu_snapshot <work_dir>}"
  printf 'imu_snapshot: not implemented (issue #2)\n' >&2
  return 1
}
