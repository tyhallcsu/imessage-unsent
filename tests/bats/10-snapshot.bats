#!/usr/bin/env bats

load helpers

@test "imu_snapshot copies the fixture-backed chat.db family" {
  root="$(imu_test_root)"
  live_dir="$root/home/Library/Messages"
  work_dir="$root/work"
  bin_dir="$root/bin"
  copy_fixture_messages "$live_dir"
  install_fake_osascript "$bin_dir"

  run env PATH="$bin_dir:$PATH" bash -c '
    source "$1/scripts/lib/snapshot.sh"
    imu_snapshot "$2" "$3" >/dev/null
  ' bash "$REPO_DIR" "$work_dir" "$live_dir"

  [ "$status" -eq 0 ]
  [ -s "$work_dir/chat.db" ]
  [ -s "$work_dir/chat.db-wal" ]
  [ -f "$work_dir/chat.db-shm" ]
}
