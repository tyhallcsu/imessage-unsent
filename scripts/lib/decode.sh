#!/usr/bin/env bash
# scripts/lib/decode.sh — Vectors 2+3: decode message_summary_info plist
# and attributedBody typedstream via scripts/decode.py.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_DECODE:-}" ]] && return
IMU_LIB_DECODE=1

set -uo pipefail

# imu_decode_blobs <ab_path> <msi_path>
#
# Invokes scripts/decode.py against attributedBody and message_summary_info
# BLOB dumps. Prints the decoder's stdout (human-readable findings).
# Returns 0 even if the BLOBs are empty — emptiness is the expected case for
# fully retracted messages.
#
imu_decode_blobs() {
  local ab_path="${1:?usage: imu_decode_blobs <ab_path> <msi_path>}"
  local msi_path="${2:?usage: imu_decode_blobs <ab_path> <msi_path>}"
  local decode_py="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/decode.py}"

  if [[ ! -f "$decode_py" ]]; then
    printf 'decode.py not found at %s\n' "$decode_py" >&2
    return 1
  fi

  python3 "$decode_py" "$ab_path" "$msi_path"
}
