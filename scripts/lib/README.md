# scripts/lib/

Modular recovery primitives sourced by `scripts/recover.sh`. This directory implements the library split for [issue #2](https://github.com/tyhallcsu/imessage-unsent/issues/2).

## Planned modules

| File | Function | Responsibility |
|---|---|---|
| `snapshot.sh` | `imu_snapshot <work_dir> [live_dir]` | Quit Messages.app and copy `chat.db` family into `<work_dir>`. |
| `scan.sh` | `imu_find_candidate <snap_db> <handle>` | Resolve handle → chat → most recent retracted inbound message. Returns `ROWID|GUID`. |
| `wal.sh` | `imu_extract_from_wal <wal_path> <guid>` | Search WAL for GUID byte string and extract pre-retract UTF-8. Returns TSV `offset<TAB>length<TAB>text`. |
| `decode.sh` | `imu_decode_blobs <ab_path> <msi_path>` | Wraps `scripts/decode.py` with a uniform shell interface. |

## Conventions

- Each lib starts with a source guard: `[[ -n "${IMU_LIB_<NAME>:-}" ]] && return; IMU_LIB_<NAME>=1`.
- Use `set -uo pipefail` (NOT `-e`) — vectors must run independently.
- Functions take explicit args; no global state.
- All paths absolute. Callers pass paths in; libs never assume `~/Library/Messages/`.
- Output to stdout; logs/diagnostics to stderr; exit codes only for hard errors.

`scripts/recover.sh` remains the user-facing driver and orchestrates the Vector 0–6 flow described in [README.md](../../README.md#the-six-recovery-vectors). JSON output, fixtures, and end-to-end tests are intentionally left to issues #3, #4, and #5.
