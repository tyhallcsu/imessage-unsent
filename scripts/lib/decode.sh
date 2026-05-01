#!/usr/bin/env bash
# Wrapper for typedstream/plist decode support.

set -uo pipefail

[[ -n "${IMU_LIB_DECODE:-}" ]] && return
IMU_LIB_DECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

imu_decode_blobs() {
  local attributed_body=$1
  local message_summary_info=$2

  if [[ ! -f "$REPO_DIR/scripts/decode.py" ]]; then
    return 1
  fi

  python3 "$REPO_DIR/scripts/decode.py" "$attributed_body" "$message_summary_info"
}
