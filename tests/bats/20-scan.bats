#!/usr/bin/env bats

load helpers

@test "imu_find_candidate returns the seeded retracted row" {
  root="$(imu_test_root)"
  live_dir="$root/home/Library/Messages"
  copy_fixture_messages "$live_dir"

  run bash -c '
    source "$1/scripts/lib/scan.sh"
    imu_find_candidate "$2/chat.db" "+15551234567"
  ' bash "$REPO_DIR" "$live_dir"

  [ "$status" -eq 0 ]
  [ "$output" = "200|$EXPECTED_GUID" ]
}
