#!/usr/bin/env bats

load helpers

@test "recover.sh --handles-file --json returns batch candidates" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"
  handles_file="$root/handles.txt"
  printf '+15551234567\n' > "$handles_file"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handles-file "$4" --since 365d --work "$5" --json 2>"$6/stderr.txt"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$handles_file" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import base64
import json
import sys

payload = json.loads(sys.argv[1])
assert payload[0]["handle"] == "+15551234567"
candidate = payload[0]["candidates"][0]
assert candidate["rowid"] == 200
text = base64.b64decode(candidate["recovered"]["text_b64"]).decode()
assert text == "Recovered fixture message: hello WAL data!"
PY
}

@test "recover.sh --all-handles --json scans fixture handles" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --all-handles --since 365d --work "$4" --json 2>"$5/stderr.txt"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert [item["handle"] for item in payload] == ["+15551234567"]
assert payload[0]["candidates"][0]["guid"] == "00000000-0000-0000-0000-000000000001"
PY
}

@test "recover.sh --dry-run lists handles without snapshotting" {
  root="$(imu_test_root)"
  handles_file="$root/handles.txt"
  work_dir="$root/work"
  printf '+15551234567\n' > "$handles_file"

  run "$REPO_DIR/scripts/recover.sh" --handles-file "$handles_file" --since 365d --work "$work_dir" --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] would scan handles"* ]]
  [[ "$output" == *"+15551234567"* ]]
  [ ! -e "$work_dir" ]
}

@test "recover.sh batch mode rate-limits repeated hot handles" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"
  handles_file="$root/handles.txt"
  printf '+15551234567\n' > "$handles_file"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handles-file "$4" --since 365d --work "$5" --json >/dev/null 2>"$6/first.stderr"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$handles_file" "$IMU_TEST_WORK" "$root"
  [ "$status" -eq 0 ]

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handles-file "$4" --since 365d --work "$5" --json 2>"$6/second.stderr"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$handles_file" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload[0]["handle"] == "+15551234567"
assert payload[0]["skipped"] is True
assert payload[0]["skip_reason"] == "rate_limited"
assert payload[0]["candidates"] == []
PY
}
