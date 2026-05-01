#!/usr/bin/env bash
# Snapshot helpers for the live Messages database family.

set -uo pipefail

[[ -n "${IMU_LIB_SNAPSHOT:-}" ]] && return
IMU_LIB_SNAPSHOT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

imu_snapshot() {
  local work_dir=$1
  local live_dir=${2:-"$HOME/Library/Messages"}
  local quit_messages=${3:-1}

  mkdir -p "$work_dir"

  if [[ "$quit_messages" == "1" ]]; then
    osascript -e 'quit app "Messages"' 2>/dev/null || true
    sleep "${IMU_SNAPSHOT_SLEEP:-2}"
  fi

  local f
  for f in chat.db chat.db-wal chat.db-shm; do
    if [[ -f "$live_dir/$f" ]]; then
      cp "$live_dir/$f" "$work_dir/$f"
    fi
  done

  [[ -f "$work_dir/chat.db" ]]
}
