#!/usr/bin/env bash
# scripts/lib/common.sh - shared helpers for the recovery libs.

[[ -n "${IMU_LIB_COMMON:-}" ]] && return
IMU_LIB_COMMON=1

set -uo pipefail

imu_sql_escape() {
  local value="${1:-}"
  printf "%s" "${value//\'/\'\'}"
}

imu_stat_size() {
  local path="$1"
  if stat -f "%z" "$path" >/dev/null 2>&1; then
    stat -f "%z" "$path"
  else
    stat -c "%s" "$path"
  fi
}

imu_stat_mtime() {
  local path="$1"
  if stat -f "%Sm" "$path" >/dev/null 2>&1; then
    stat -f "%Sm" "$path"
  else
    stat -c "%y" "$path"
  fi
}

imu_iso_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}
