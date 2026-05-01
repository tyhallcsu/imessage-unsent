#!/usr/bin/env bash
# scripts/lib/wal.sh — Vector 4: extract pre-retract UTF-8 from chat.db-wal.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_WAL:-}" ]] && return
IMU_LIB_WAL=1

set -uo pipefail

# imu_extract_from_wal <wal_path> <guid>
#
# Searches <wal_path> for byte occurrences of <guid> (36-byte ASCII), and for
# each occurrence extracts the bytes immediately following until the typedstream
# magic (b'\x04\x0bstreamtyped'). Returns TSV on stdout:
#   <wal_offset>\t<text_length>\t<text>
# One line per distinct candidate. Empty stdout = no candidates.
#
# See README "Why the WAL vector works" for the byte-level rationale.
#
imu_extract_from_wal() {
  local wal_path="${1:?usage: imu_extract_from_wal <wal_path> <guid>}"
  local guid="${2:?usage: imu_extract_from_wal <wal_path> <guid>}"
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$lib_dir/wal_extract.py" "$wal_path" "$guid"
}
