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

# Portable octal file-mode accessor: BSD stat (macOS) then GNU stat (Linux CI).
imu_mode() {
  local target="${1:?usage: imu_mode <path>}"
  stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target"
}

copy_fixture_messages() {
  local destination="${1:?usage: copy_fixture_messages <destination>}"
  mkdir -p "$destination"
  cp "$FIXTURE_DIR/chat.db" "$FIXTURE_DIR/chat.db-wal" "$destination/"
  : > "$destination/chat.db-shm"
}

copy_fixture_iphone_backup() {
  local destination="${1:?usage: copy_fixture_iphone_backup <destination>}"
  python3 - "$FIXTURE_DIR/iphone-backup" "$destination" <<'PY'
import os
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
shutil.rmtree(destination, ignore_errors=True)
shutil.copytree(source, destination, copy_function=shutil.copy2)

backup_unix_time = int((797000000000000010 / 1_000_000_000) + 978_307_200 + 10)
for path in [destination, *destination.rglob("*")]:
    os.utime(path, (backup_unix_time, backup_unix_time))
PY
}

install_fake_osascript() {
  local bin_dir="${1:?usage: install_fake_osascript <bin_dir>}"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/osascript"
  chmod +x "$bin_dir/osascript"
}

setup_fixture_recover_env() {
  local root="${1:?usage: setup_fixture_recover_env <root>}"
  IMU_TEST_HOME="$root/home"
  IMU_TEST_WORK="$root/work"
  IMU_TEST_BIN="$root/bin"
  copy_fixture_messages "$IMU_TEST_HOME/Library/Messages"
  install_fake_osascript "$IMU_TEST_BIN"
}
