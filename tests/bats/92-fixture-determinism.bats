#!/usr/bin/env bats

# Issue #165 — the fixture builder must produce the same bytes every time.
#
# SQLite stamps its own version into every database header at offset 96. Until
# this was pinned, rebuilding on a machine with a different SQLite rewrote two
# bytes per file and left the working tree dirty after every `make test` —
# twice resulting in unrelated binary churn being committed.
#
# These tests cover run-to-run determinism and the pinning itself. The stricter
# guard — that the *committed* fixture matches what the builder produces — is a
# CI step (`make fixture && git diff --exit-code tests/fixtures/`), because CI
# rebuilds the fixture before bats runs, which would make a working-tree
# comparison here compare a rebuild against a rebuild.

load helpers

FIXTURE_FILES=(
  "chat.db"
  "chat.db-wal"
  "iphone-backup/Manifest.db"
  "iphone-backup/3d/3d0d7e5fb2ce288813306e4d4636395e047a3d28"
)

@test "build-fixture.sh is byte-identical across two consecutive runs" {
  local root first second
  root="$(imu_test_root)"
  first="$root/build-1"
  second="$root/build-2"
  mkdir -p "$first" "$second"

  run "$REPO_DIR/tests/fixtures/build-fixture.sh" "$first"
  [ "$status" -eq 0 ]
  run "$REPO_DIR/tests/fixtures/build-fixture.sh" "$second"
  [ "$status" -eq 0 ]

  for name in "${FIXTURE_FILES[@]}"; do
    cmp "$first/$name" "$second/$name"
  done
}

@test "every generated database carries the pinned SQLite version stamp" {
  local root out
  root="$(imu_test_root)"
  out="$root/build"
  mkdir -p "$out"

  run "$REPO_DIR/tests/fixtures/build-fixture.sh" "$out"
  [ "$status" -eq 0 ]

  # Reads the 4-byte SQLITE_VERSION_NUMBER at header offset 96 and compares it
  # against the constant in build-fixture.sh. A mismatch means a rebuild on a
  # different SQLite would drift again.
  run python3 - "$out" "$REPO_DIR/tests/fixtures/build-fixture.sh" <<'PY'
import re
import struct
import sys
from pathlib import Path

out = Path(sys.argv[1])
builder = Path(sys.argv[2]).read_text()
match = re.search(r"^FIXTURE_SQLITE_VERSION = ([\d_]+)$", builder, re.M)
if not match:
    raise SystemExit("could not find FIXTURE_SQLITE_VERSION in build-fixture.sh")
expected = int(match.group(1).replace("_", ""))

databases = [
    out / "chat.db",
    out / "iphone-backup" / "Manifest.db",
    out / "iphone-backup" / "3d" / "3d0d7e5fb2ce288813306e4d4636395e047a3d28",
]
for path in databases:
    stamp = struct.unpack(">I", path.read_bytes()[96:100])[0]
    if stamp != expected:
        raise SystemExit(f"{path.name}: stamp {stamp} != pinned {expected}")

# Page 1 holds the database header, and the fixture's WAL carries several
# copies of it. Pinning only chat.db would leave those drifting.
wal = (out / "chat.db-wal").read_bytes()
page_size = struct.unpack(">I", wal[8:12])[0]
frame_size = 24 + page_size
page_one_frames = 0
for offset in range(32, len(wal), frame_size):
    if struct.unpack(">I", wal[offset:offset + 4])[0] != 1:
        continue
    page_one_frames += 1
    stamp_at = offset + 24 + 96
    stamp = struct.unpack(">I", wal[stamp_at:stamp_at + 4])[0]
    if stamp != expected:
        raise SystemExit(f"WAL frame at {offset}: stamp {stamp} != pinned {expected}")

if page_one_frames == 0:
    raise SystemExit("expected the fixture WAL to contain page-1 frames")
print(f"ok: {len(databases)} databases + {page_one_frames} WAL page-1 frames pinned")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAL page-1 frames pinned"* ]]
}

@test "the fixture WAL still validates after the version stamp is rewritten" {
  # Patching page-1 images invalidates the frame checksums, so normalize_wal()
  # has to run afterwards. If that ordering ever inverts, recovery silently
  # stops finding the message in the WAL.
  local root out
  root="$(imu_test_root)"
  out="$root/build"
  mkdir -p "$out"

  run "$REPO_DIR/tests/fixtures/build-fixture.sh" "$out"
  [ "$status" -eq 0 ]

  run python3 "$REPO_DIR/scripts/lib/wal_extract.py" "$out/chat.db-wal" "$EXPECTED_GUID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$EXPECTED_TEXT"* ]]
}
