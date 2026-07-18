#!/usr/bin/env bats

# Issue #112 (F-M1) — the CLI must not write a chat.db snapshot + recovered
# plaintext to a predictable, world-traversable location. All runs use the
# synthetic fixture via a HOME override; the live Messages DB is never touched.

load helpers

@test "recover.sh hardens a user --work dir to 0700 and never deletes it" {
  local root
  root="$(imu_test_root)/wh-user"
  setup_fixture_recover_env "$root"

  run env \
    PATH="$IMU_TEST_BIN:$PATH" \
    HOME="$IMU_TEST_HOME" \
    "$REPO_DIR/scripts/recover.sh" \
    --handle '+15551234567' \
    --work "$IMU_TEST_WORK" \
    --json

  [ "$status" -eq 0 ]
  [[ "$output" == *"$EXPECTED_GUID"* ]]

  # User-supplied work dir persists and is owner-only.
  [ -d "$IMU_TEST_WORK" ]
  [ "$(imu_mode "$IMU_TEST_WORK")" = "700" ]

  # Sensitive artifacts inside it are owner-only too (umask 077).
  [ -f "$IMU_TEST_WORK/report.txt" ]
  [ "$(imu_mode "$IMU_TEST_WORK/report.txt")" = "600" ]
  [ -f "$IMU_TEST_WORK/chat.db" ]
  [ "$(imu_mode "$IMU_TEST_WORK/chat.db")" = "600" ]
}

@test "recover.sh default work dir is private under TMPDIR and auto-cleaned" {
  local root
  root="$(imu_test_root)/wh-default"
  setup_fixture_recover_env "$root"
  local tmp="$root/tmpdir"
  mkdir -p "$tmp"

  # No --work: the script must create its own private dir under $TMPDIR.
  run env \
    PATH="$IMU_TEST_BIN:$PATH" \
    HOME="$IMU_TEST_HOME" \
    TMPDIR="$tmp" \
    "$REPO_DIR/scripts/recover.sh" \
    --handle '+15551234567' \
    --json

  [ "$status" -eq 0 ]
  [[ "$output" == *"$EXPECTED_GUID"* ]]

  # The auto-created dir was removed on exit — nothing left behind.
  run bash -c "ls -d '$tmp'/imessage-recovery.* 2>/dev/null"
  [ "$status" -ne 0 ]

  # And the old predictable path is never used.
  [ ! -e "$tmp/imessage-recovery" ]
}

@test "recover.sh errors cleanly when its private TMPDIR is not writable" {
  local root
  root="$(imu_test_root)/wh-nowrite"
  setup_fixture_recover_env "$root"
  local tmp="$root/ro-tmp"
  mkdir -p "$tmp"
  chmod 500 "$tmp"

  run env \
    PATH="$IMU_TEST_BIN:$PATH" \
    HOME="$IMU_TEST_HOME" \
    TMPDIR="$tmp" \
    "$REPO_DIR/scripts/recover.sh" \
    --handle '+15551234567' \
    --json

  chmod 700 "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"private work directory"* ]] || [[ "$output" == *"could not create"* ]]
}
