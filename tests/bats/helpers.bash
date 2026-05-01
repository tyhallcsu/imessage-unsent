#!/usr/bin/env bash
# shellcheck disable=SC2034

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURE_DIR="$REPO_DIR/tests/fixtures"
EXPECTED_GUID="00000000-0000-0000-0000-000000000001"
EXPECTED_TEXT="Recovered fixture message: hello WAL data!"

imu_test_root() {
  if [[ -n "${BATS_TEST_TMPDIR:-}" ]]; then
    printf "%s\n" "$BATS_TEST_TMPDIR"
  else
    mktemp -d
  fi
}

copy_fixture_messages() {
  local destination="${1:?usage: copy_fixture_messages <destination>}"
  mkdir -p "$destination"
  cp "$FIXTURE_DIR/chat.db" "$FIXTURE_DIR/chat.db-wal" "$destination/"
  : > "$destination/chat.db-shm"
}

install_fake_osascript() {
  local bin_dir="${1:?usage: install_fake_osascript <bin_dir>}"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/osascript"
  chmod +x "$bin_dir/osascript"
}
