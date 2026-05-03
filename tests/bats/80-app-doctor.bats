#!/usr/bin/env bats

load helpers

# scripts/app_doctor.sh against an empty fake HOME — every daemon check should
# fail, but the script must exit 0 (it's a diagnostic, not a gate).
@test "app_doctor.sh exits 0 against empty fake HOME and reports failures" {
  HOME="$(imu_test_root)" run "$REPO_DIR/scripts/app_doctor.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"imessage-unsent diagnostics"* ]]
  [[ "$output" == *"[FAIL] daemon.binary"* ]]
  [[ "$output" == *"[FAIL] daemon.plist"* ]]
  [[ "$output" == *"make daemon-install"* ]]
}

# Faked install tree: binary, plist, and recovery script all present →
# corresponding daemon checks must report PASS.
@test "app_doctor.sh reports PASS for binary/plist/scripts when faked install exists" {
  fake_home="$(imu_test_root)"
  app_support="$fake_home/Library/Application Support/imessage-unsent"
  mkdir -p "$app_support/bin" "$app_support/scripts" "$app_support/archives"
  mkdir -p "$fake_home/Library/LaunchAgents"
  printf '#!/bin/sh\nexit 0\n' > "$app_support/bin/imu-watcher"
  chmod +x "$app_support/bin/imu-watcher"
  printf '#!/bin/sh\nexit 0\n' > "$app_support/scripts/recover.sh"
  chmod +x "$app_support/scripts/recover.sh"
  : > "$fake_home/Library/LaunchAgents/com.imu.watcher.plist"

  HOME="$fake_home" run "$REPO_DIR/scripts/app_doctor.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] daemon.binary"* ]]
  [[ "$output" == *"[PASS] daemon.plist"* ]]
  [[ "$output" == *"[PASS] daemon.scripts"* ]]
  # archives dir is present and empty → INFO with "0 entries"
  [[ "$output" == *"[INFO] archive.dir"* ]]
  [[ "$output" == *"0 entries"* ]]
}

# The diagnostic must not include any chat.db content or config secrets, even
# when those files are present in the fake home. We check for a stable marker
# string we plant ourselves.
@test "app_doctor.sh never prints config or message content" {
  fake_home="$(imu_test_root)"
  mkdir -p "$fake_home/.config/imessage-unsent"
  echo 'webhook_url = "https://example.com/SECRET-MARKER-DO-NOT-LEAK"' > "$fake_home/.config/imessage-unsent/config.toml"

  HOME="$fake_home" run "$REPO_DIR/scripts/app_doctor.sh"

  [ "$status" -eq 0 ]
  [[ "$output" != *"SECRET-MARKER-DO-NOT-LEAK"* ]]
}
