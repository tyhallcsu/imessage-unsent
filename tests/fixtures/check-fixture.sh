#!/usr/bin/env bash
# Verify the synthetic fixture through the public JSON CLI path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/home/Library/Messages" "$TMP_DIR/bin" "$TMP_DIR/work"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/osascript"
chmod +x "$TMP_DIR/bin/osascript"

cp "$SCRIPT_DIR/chat.db" "$SCRIPT_DIR/chat.db-wal" "$TMP_DIR/home/Library/Messages/"
: > "$TMP_DIR/home/Library/Messages/chat.db-shm"

PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
  "$REPO_DIR/scripts/recover.sh" \
    --handle '+15551234567' \
    --work "$TMP_DIR/work" \
    --json > "$TMP_DIR/stdout.json" \
    2> "$TMP_DIR/stderr.txt"

python3 - "$TMP_DIR/stdout.json" <<'PY'
import base64
import json
import sys

payload = json.load(open(sys.argv[1]))
text = base64.b64decode(payload["recovered"]["text_b64"]).decode()

assert payload["schema_version"] == 1
assert payload["candidate"]["rowid"] == 200
assert payload["candidate"]["msi_otr_le"] == 42
assert text == "Recovered fixture message: hello WAL data!"

print("fixture-recovery-json-ok")
PY
