# scripts/lib/

Modular recovery primitives sourced by `scripts/recover.sh`. This directory implements the library split for [issue #2](https://github.com/tyhallcsu/imessage-unsent/issues/2).

## Planned modules

| File | Function | Responsibility |
|---|---|---|
| `snapshot.sh` | `imu_snapshot <work_dir> [live_dir]` | Quit Messages.app and copy `chat.db` family into `<work_dir>`. |
| `scan.sh` | `imu_find_candidate <snap_db> <handle>` | Resolve handle → chat → most recent retracted inbound message. Returns `ROWID|GUID`. |
| `wal.sh` | `imu_extract_from_wal <wal_path> <guid>` | Search WAL for GUID byte string and extract pre-retract UTF-8. Returns TSV `offset<TAB>length<TAB>text`. |
| `decode.sh` | `imu_decode_blobs <ab_path> <msi_path>` | Wraps `scripts/decode.py` with a uniform shell interface. |

## Python helpers

| File | Consumed by | Responsibility |
|---|---|---|
| `wal_extract.py` | `wal.sh` | Vector 4 byte-forensics core — scan WAL frames for the pre-retract page. |
| `wal_merge_candidates.py` | `recover.sh` | Merge live-WAL hits with the daemon's rolling snapshot buffer (PR #68). |
| `json_report.py` | `recover.sh --json` | Emit the final recovery report. |
| `batch_report.py` | `recover.sh --handles-file` | Aggregate batch-mode results. |
| `iphone_backup.py` | `recover.sh --include-iphone-backup` | Vector 6 lookup in unencrypted iPhone backups. |
| `recovery_selection.py` | `recover.sh` | Pick the best candidate across vectors. |
| `chatdb_time.py` | `edit-history.py`, `read-receipts.py` | Shared Apple-epoch conversion, `--since` parsing, and the read-only SQLite connection for the standalone Vector 7 / Vector 8 CLIs. |

## Conventions

- Each lib starts with a source guard: `[[ -n "${IMU_LIB_<NAME>:-}" ]] && return; IMU_LIB_<NAME>=1`.
- Use `set -uo pipefail` (NOT `-e`) — vectors must run independently.
- Functions take explicit args; no global state.
- All paths absolute. Callers pass paths in; libs never assume `~/Library/Messages/`.
- Output to stdout; logs/diagnostics to stderr; exit codes only for hard errors.

`scripts/recover.sh` remains the user-facing driver and orchestrates the Vector 0–6 flow described in [README.md](../../README.md#the-six-recovery-vectors). JSON output is layered on top of these primitives; fixtures and end-to-end tests are intentionally left to issues #4 and #5.
