"""Tests for `scripts/lib/chatdb_time.py` — the shared epoch/duration helpers.

`edit-history.py` (Vector 7) and `read-receipts.py` (Vector 8) both depend on
this module, so a regression here silently skews every timestamp both tools
print.
"""
from __future__ import annotations

import importlib.util
import sys

import pytest


def _load(repo_root):
    path = repo_root / "scripts" / "lib" / "chatdb_time.py"
    spec = importlib.util.spec_from_file_location("imu_chatdb_time", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["imu_chatdb_time"] = module
    spec.loader.exec_module(module)
    return module


def test_normalize_upconverts_legacy_second_precision(repo_root):
    """Pre-High-Sierra rows store Apple-epoch *seconds*, not nanoseconds."""
    module = _load(repo_root)
    assert module.normalize_apple_ts(797_000_000) == 797_000_000_000_000_000
    # Already-nanosecond values pass through untouched.
    assert module.normalize_apple_ts(797_000_000_000_000_000) == 797_000_000_000_000_000


def test_unset_timestamps_stay_unset(repo_root):
    """chat.db uses 0 for "no value" — it must not render as 2001-01-01."""
    module = _load(repo_root)
    assert module.normalize_apple_ts(0) == 0
    assert module.normalize_apple_ts(None) == 0
    assert module.apple_ns_to_unix_ns(0) == 0
    assert module.apple_ns_to_iso(0) == ""
    assert module.apple_ns_to_iso(None) == ""


def test_apple_to_unix_offset(repo_root):
    module = _load(repo_root)
    # Apple epoch zero == 2001-01-01T00:00:00Z == 978307200 UNIX.
    assert module.apple_ns_to_unix_ns(797_000_000_000_000_000) == (
        797_000_000_000_000_000 + 978_307_200 * 1_000_000_000
    )
    # Seconds and nanoseconds land on the same instant.
    assert module.apple_ns_to_unix_ns(797_000_000) == module.apple_ns_to_unix_ns(
        797_000_000_000_000_000
    )


def test_iso_rendering_is_stable(repo_root):
    module = _load(repo_root)
    rendered = module.apple_ns_to_iso(797_000_000_000_000_000)
    assert rendered.startswith("2026-04-04")


def test_parse_since_units(repo_root):
    module = _load(repo_root)
    assert module.parse_since("all") is None
    assert module.parse_since("any") is None
    assert module.parse_since("30s") == 30 * 1_000_000_000
    assert module.parse_since("15m") == 15 * 60 * 1_000_000_000
    assert module.parse_since("24h") == 24 * 3_600 * 1_000_000_000
    assert module.parse_since("7d") == 7 * 86_400 * 1_000_000_000


def test_parse_since_rejects_garbage(repo_root):
    module = _load(repo_root)
    with pytest.raises(SystemExit):
        module.parse_since("last tuesday")
    with pytest.raises(SystemExit):
        module.parse_since("7w")


def test_connect_readonly_rejects_missing_db(repo_root, tmp_path):
    module = _load(repo_root)
    with pytest.raises(SystemExit):
        module.connect_readonly(tmp_path / "nope.db")


def test_connect_readonly_cannot_write(repo_root, fixture_messages):
    import sqlite3

    module = _load(repo_root)
    conn = module.connect_readonly(fixture_messages / "chat.db")
    try:
        with pytest.raises(sqlite3.OperationalError):
            conn.execute("UPDATE message SET text = 'nope' WHERE ROWID = 400")
    finally:
        conn.close()
