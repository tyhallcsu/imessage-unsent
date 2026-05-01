#!/usr/bin/env bats

load helpers

@test "imu_extract_from_wal returns the seeded text and length" {
  root="$(imu_test_root)"
  live_dir="$root/home/Library/Messages"
  copy_fixture_messages "$live_dir"

  run bash -c '
    source "$1/scripts/lib/wal.sh"
    imu_extract_from_wal "$2/chat.db-wal" "$3"
  ' bash "$REPO_DIR" "$live_dir" "$EXPECTED_GUID"

  [ "$status" -eq 0 ]
  IFS=$'\t' read -r _offset length text <<< "$output"
  [ "$length" = "42" ]
  [ "$text" = "$EXPECTED_TEXT" ]
}
