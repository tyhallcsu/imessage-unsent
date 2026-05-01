#!/usr/bin/env bats

setup() {
  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixture"
  WORK_DIR="$BATS_TEST_TMPDIR/work"
  mkdir -p "$FIXTURE_DIR" "$WORK_DIR"
  ./tests/fixtures/build-fixture.sh "$FIXTURE_DIR" >/dev/null
  cp "$FIXTURE_DIR"/chat.db* "$WORK_DIR"/
}

@test "recover.sh --json recovers the synthetic WAL fixture text" {
  run ./scripts/recover.sh --handle "+15551234567" --work "$WORK_DIR" --no-snapshot --json
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import base64
import json
import sys

payload = json.loads(sys.argv[1].splitlines()[-1])
assert payload["schema_version"] == 1
assert payload["candidate"]["rowid"] == 200
text = base64.b64decode(payload["recovered"]["text_b64"]).decode()
assert text == "Recovered fixture message: hello WAL data!"
assert payload["candidate"]["msi_otr_le"] == 42
PY
}
