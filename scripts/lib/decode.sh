#!/usr/bin/env bash
# scripts/lib/decode.sh — Vectors 2+3: decode message_summary_info plist
# and attributedBody typedstream via scripts/decode.py.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_DECODE:-}" ]] && return
IMU_LIB_DECODE=1

# imu_decode_blobs <ab_path> <msi_path>
#
# Invokes scripts/decode.py against attributedBody and message_summary_info
# BLOB dumps. Prints the decoder's stdout (human-readable findings).
# Returns 0 even if the BLOBs are empty — emptiness is the expected case for
# fully retracted messages.
#
# TODO(#2): port from scripts/recover.sh, Step 3 (typedstream decode).
imu_decode_blobs() {
  local ab_path="${1:?usage: imu_decode_blobs <ab_path> <msi_path>}"
  local msi_path="${2:?usage: imu_decode_blobs <ab_path> <msi_path>}"
  printf 'imu_decode_blobs: not implemented (issue #2)\n' >&2
  return 1
}
