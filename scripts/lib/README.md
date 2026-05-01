# scripts/lib/

Modular recovery primitives sourced by `scripts/recover.sh`. **This directory is the planned structure for [issue #2](https://github.com/tyhallcsu/imessage-unsent/issues/2) — currently scaffolded but not implemented.**

## Planned modules

| File | Function | Responsibility |
|---|---|---|
| `snapshot.sh` | `imu_snapshot <work_dir>` | Quit Messages.app and copy `chat.db` family into `<work_dir>`. |
| `scan.sh` | `imu_find_candidate <snap_db> <handle>` | Resolve handle → chat → most recent retracted inbound message. Returns `ROWID|GUID`. |
| `wal.sh` | `imu_extract_from_wal <wal_path> <guid>` | Search WAL for GUID byte string and extract pre-retract UTF-8. Returns TSV `offset<TAB>length<TAB>text_b64`. |
| `decode.sh` | `imu_decode_blobs <ab_path> <msi_path>` | Wraps `scripts/decode.py` with a uniform shell interface. |

## Conventions

- Each lib starts with a source guard: `[[ -n "${IMU_LIB_<NAME>:-}" ]] && return; IMU_LIB_<NAME>=1`.
- Use `set -uo pipefail` (NOT `-e`) — vectors must run independently.
- Functions take explicit args; no global state.
- All paths absolute. Callers pass paths in; libs never assume `~/Library/Messages/`.
- Output to stdout; logs/diagnostics to stderr; exit codes only for hard errors.

## After this lands

`scripts/recover.sh` becomes a thin driver that sources these libs and orchestrates the Vector 0–6 flow described in [README.md](../../README.md#the-six-recovery-vectors). All existing CLI behavior is preserved; tests (issue #5) verify against the fixture (issue #4).

## Status

This README + the four `.sh` stub files in this directory are the scaffolding for issue #2's PR. The actual implementation is the work of that PR.
