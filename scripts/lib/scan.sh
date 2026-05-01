#!/usr/bin/env bash
# scripts/lib/scan.sh — Vector 1: handle → chat → retracted-message candidate.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_SCAN:-}" ]] && return
IMU_LIB_SCAN=1

# imu_find_candidate <snap_db> <handle>
#
# Resolves <handle> (E.164 phone or Apple ID email) to the most recent inbound
# retracted message in the corresponding chat. Returns one line: <ROWID>|<GUID>.
# Empty stdout = no candidate found.
#
# Predicate (verified on macOS Sequoia / Darwin 24.x):
#   m.is_from_me = 0
#   AND m.date_edited != 0     -- NOT date_retracted (unused on Darwin 24)
#   AND m.is_empty   = 1
#
# TODO(#2): port from scripts/recover.sh, Step 1 (Locate chat by handle).
imu_find_candidate() {
  local snap_db="${1:?usage: imu_find_candidate <snap_db> <handle>}"
  local handle="${2:?usage: imu_find_candidate <snap_db> <handle>}"
  printf 'imu_find_candidate: not implemented (issue #2)\n' >&2
  return 1
}
