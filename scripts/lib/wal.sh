#!/usr/bin/env bash
# WAL byte-forensics helpers.

set -uo pipefail

[[ -n "${IMU_LIB_WAL:-}" ]] && return
IMU_LIB_WAL=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

imu_extract_from_wal() {
  local wal_path=$1
  local guid=$2
  python3 "$SCRIPT_DIR/wal_extract.py" "$wal_path" "$guid"
}

imu_extract_from_wal_json() {
  local wal_path=$1
  local guid=$2
  python3 "$SCRIPT_DIR/wal_extract.py" --json "$wal_path" "$guid"
}
