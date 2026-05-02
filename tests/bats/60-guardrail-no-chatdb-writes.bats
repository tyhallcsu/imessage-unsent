#!/usr/bin/env bats

# Issue #17 — Notify-only invariant guardrail.
# A full recover.sh run against a fixture-backed "live" Messages directory must
# leave chat.db, chat.db-wal, and chat.db-shm byte-identical. If any future PR
# accidentally introduces a write path to the live DB, the sha256 mismatch
# fails this test before review.
#
# This test exercises the public CLI surface; a parallel Swift-side guard in
# IMUCore (`RestoreModeGuard`) covers the daemon path.

load helpers

@test "recover.sh leaves the live chat.db family byte-identical (Notify-only)" {
  local root
  root="$(imu_test_root)/run-1"
  setup_fixture_recover_env "$root"

  local live_dir="$IMU_TEST_HOME/Library/Messages"

  local before_db before_wal before_shm
  before_db=$(shasum -a 256 "$live_dir/chat.db" | awk '{print $1}')
  before_wal=$(shasum -a 256 "$live_dir/chat.db-wal" | awk '{print $1}')
  before_shm=$(shasum -a 256 "$live_dir/chat.db-shm" | awk '{print $1}')

  run env \
    PATH="$IMU_TEST_BIN:$PATH" \
    HOME="$IMU_TEST_HOME" \
    "$REPO_DIR/scripts/recover.sh" \
    --handle '+15551234567' \
    --work "$IMU_TEST_WORK" \
    --json

  [ "$status" -eq 0 ]
  [[ "$output" == *"$EXPECTED_GUID"* ]]

  local after_db after_wal after_shm
  after_db=$(shasum -a 256 "$live_dir/chat.db" | awk '{print $1}')
  after_wal=$(shasum -a 256 "$live_dir/chat.db-wal" | awk '{print $1}')
  after_shm=$(shasum -a 256 "$live_dir/chat.db-shm" | awk '{print $1}')

  [ "$before_db" = "$after_db" ]
  [ "$before_wal" = "$after_wal" ]
  [ "$before_shm" = "$after_shm" ]
}

@test "recover.sh batch mode leaves the live chat.db family byte-identical" {
  local root
  root="$(imu_test_root)/run-2"
  setup_fixture_recover_env "$root"

  local live_dir="$IMU_TEST_HOME/Library/Messages"
  local handles_file="$root/handles.txt"
  printf '+15551234567\n' > "$handles_file"

  local before_db before_wal before_shm
  before_db=$(shasum -a 256 "$live_dir/chat.db" | awk '{print $1}')
  before_wal=$(shasum -a 256 "$live_dir/chat.db-wal" | awk '{print $1}')
  before_shm=$(shasum -a 256 "$live_dir/chat.db-shm" | awk '{print $1}')

  run env \
    PATH="$IMU_TEST_BIN:$PATH" \
    HOME="$IMU_TEST_HOME" \
    "$REPO_DIR/scripts/recover.sh" \
    --handles-file "$handles_file" \
    --since 30d \
    --work "$IMU_TEST_WORK" \
    --json

  [ "$status" -eq 0 ]

  local after_db after_wal after_shm
  after_db=$(shasum -a 256 "$live_dir/chat.db" | awk '{print $1}')
  after_wal=$(shasum -a 256 "$live_dir/chat.db-wal" | awk '{print $1}')
  after_shm=$(shasum -a 256 "$live_dir/chat.db-shm" | awk '{print $1}')

  [ "$before_db" = "$after_db" ]
  [ "$before_wal" = "$after_wal" ]
  [ "$before_shm" = "$after_shm" ]
}
