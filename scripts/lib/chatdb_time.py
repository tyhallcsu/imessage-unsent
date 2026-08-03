#!/usr/bin/env python3
"""Shared chat.db time/connection helpers for the standalone Python CLIs.

`scripts/edit-history.py` (Vector 7) and `scripts/read-receipts.py` (Vector 8)
both walk `message` rows and both need the same three things: an Apple-epoch
conversion, a `--since` duration parser, and a read-only SQLite connection.
This module is the single implementation so the epoch handling cannot drift
between the two tools.

Read-only by design — `connect_readonly` opens a `mode=ro` SQLite URI and this
module never issues a write.
"""
from __future__ import annotations

import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

APPLE_EPOCH_OFFSET = 978_307_200  # seconds between 1970-01-01 and 2001-01-01

# Apple-epoch *seconds* top out around 1.5e9 for any plausible date, so any
# magnitude at or above this is nanosecond-precision. Modern chat.db files
# (High Sierra onward) are entirely ns; second-precision rows survive in
# migrated-forward databases and in some third-party exports.
#
# The ambiguous band is the first ~100 seconds after 2001-01-01T00:00:00Z,
# which no real message occupies — a raw ns value there is read as seconds.
_NS_PRECISION_FLOOR = 100_000_000_000


def normalize_apple_ts(value: int | float | None) -> int:
    """Return Apple-epoch **nanoseconds** for a raw `message` timestamp column.

    Upconverts legacy second-precision values so callers never have to care
    which era the row came from. Returns 0 for NULL / 0 (chat.db's "unset").
    """
    if not value:
        return 0
    ns = int(value)
    if abs(ns) < _NS_PRECISION_FLOOR:
        return ns * 1_000_000_000
    return ns


def apple_ns_to_unix_ns(ns: int | float | None) -> int:
    """Apple-epoch ns (or legacy seconds) → UNIX-epoch ns. 0 stays 0."""
    normalized = normalize_apple_ts(ns)
    if normalized == 0:
        return 0
    return normalized + APPLE_EPOCH_OFFSET * 1_000_000_000


def apple_ns_to_iso(ns: int | float | None) -> str:
    """Apple-epoch ns (or legacy seconds) → local-time display string.

    Returns "" for unset timestamps so callers can distinguish "no value"
    from "epoch zero".
    """
    normalized = normalize_apple_ts(ns)
    if normalized == 0:
        return ""
    seconds = normalized / 1_000_000_000 + APPLE_EPOCH_OFFSET
    return datetime.fromtimestamp(seconds, tz=timezone.utc).astimezone().strftime(
        "%Y-%m-%d %H:%M:%S %Z"
    )


def parse_since(value: str) -> int | None:
    """Convert a `--since` duration to nanoseconds-from-now. None means `all`."""
    if value.lower() in ("all", "any", ""):
        return None
    m = re.fullmatch(r"(\d+)([smhd])", value.strip().lower())
    if not m:
        raise SystemExit(f"--since: bad duration {value!r} (expected e.g. 24h, 7d, all)")
    n = int(m.group(1))
    units = {"s": 1, "m": 60, "h": 3_600, "d": 86_400}
    return n * units[m.group(2)] * 1_000_000_000


def since_ns_to_apple_cutoff(since_ns: int) -> int:
    """`--since` window → the Apple-epoch ns cutoff to compare `date` against."""
    now_ns = int(datetime.now(tz=timezone.utc).timestamp() * 1_000_000_000)
    return now_ns - since_ns - APPLE_EPOCH_OFFSET * 1_000_000_000


def connect_readonly(path: Path) -> sqlite3.Connection:
    """Open chat.db read-only. Never opens a writable handle on the live DB.

    Caveat worth knowing before pointing this at `~/Library/Messages/chat.db`:
    `mode=ro` guarantees no write to `chat.db` or `chat.db-wal`, but SQLite
    still rebuilds the shared WAL index (`chat.db-shm`) when it attaches to a
    WAL-mode database. That file is a rebuildable index, not message data, and
    Messages.app rewrites it constantly itself — but it does mean "read-only"
    here means *the database is not modified*, not *no byte on disk moves*.

    We do not pass `immutable=1` to avoid it: that flag tells SQLite to ignore
    the WAL, and the WAL is exactly where this project's un-checkpointed rows
    live. Use `recover.sh`'s snapshot (Vector 0) when you need a frozen copy.
    """
    if not path.exists():
        raise SystemExit(f"chat.db not found: {path}")
    uri = f"file:{path}?mode=ro"
    return sqlite3.connect(uri, uri=True)
