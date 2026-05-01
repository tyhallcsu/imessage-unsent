#!/usr/bin/env bats

load helpers

@test "recover.sh --include-iphone-backup explicit path recovers when WAL misses" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"
  sqlite3 "$IMU_TEST_HOME/Library/Messages/chat.db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  backup_dir="$root/iphone-backup"
  copy_fixture_iphone_backup "$backup_dir"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handle "+15551234567" \
      --include-iphone-backup "$4" \
      --work "$5" \
      --json 2>"$6/stderr.txt"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$backup_dir" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import base64
import json
import sys

payload = json.loads(sys.argv[1])
vector = payload["vectors"]["iphone_backup"]
assert vector["hit"] is True
assert payload["recovered"]["source"] == "iphone_backup"
assert base64.b64decode(payload["recovered"]["text_b64"]).decode() == "Recovered fixture message: hello WAL data!"
PY
}

@test "recover.sh --include-iphone-backup auto-discovers matching MobileSync backup" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"
  backup_dir="$IMU_TEST_HOME/Library/Application Support/MobileSync/Backup/fixture-backup"
  copy_fixture_iphone_backup "$backup_dir"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handle "+15551234567" \
      --include-iphone-backup \
      --work "$4" \
      --json 2>"$5/stderr.txt"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
vector = payload["vectors"]["iphone_backup"]
assert vector["hit"] is True
assert vector["backup"]["source"] == "manifest"
assert vector["backup"]["root"].endswith("fixture-backup")
PY
}

@test "recover.sh --include-iphone-backup reads configured custom backup paths" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"
  backup_dir="$root/custom-backups/imazing-fixture"
  copy_fixture_iphone_backup "$backup_dir"
  mkdir -p "$IMU_TEST_HOME/.config/imessage-unsent"
  printf '%s\n' "$backup_dir" > "$IMU_TEST_HOME/.config/imessage-unsent/iphone-backup-paths.txt"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handle "+15551234567" \
      --include-iphone-backup \
      --work "$4" \
      --json 2>"$5/stderr.txt"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
vector = payload["vectors"]["iphone_backup"]
assert vector["hit"] is True
assert vector["backup"]["root"].endswith("imazing-fixture")
PY
}

@test "recover.sh --include-iphone-backup reports unreadable encrypted backup clearly" {
  root="$(imu_test_root)"
  setup_fixture_recover_env "$root"
  encrypted="$root/encrypted-sms.db"
  printf 'not sqlite encrypted fixture\n' > "$encrypted"

  run bash -c '
    PATH="$1:$PATH" HOME="$2" "$3/scripts/recover.sh" \
      --handle "+15551234567" \
      --include-iphone-backup "$4" \
      --work "$5" \
      --json 2>"$6/stderr.txt"
  ' bash "$IMU_TEST_BIN" "$IMU_TEST_HOME" "$REPO_DIR" "$encrypted" "$IMU_TEST_WORK" "$root"

  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
vector = payload["vectors"]["iphone_backup"]
assert vector["hit"] is False
assert "encrypted backups must be decrypted first" in vector["reason"]
PY
}
