"""Tests for `scripts/edit-history.py` against the synthetic fixture.

The fixture builder writes one edited row at ROWID 300 with a 2-version
`ec` chain. These tests exercise both the library entry point (via
``importlib`` because the script has a hyphen in its name) and the JSON
CLI path.
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path


def _load_module(repo_root: Path):
    script = repo_root / "scripts" / "edit-history.py"
    spec = importlib.util.spec_from_file_location("imu_edit_history", script)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["imu_edit_history"] = module
    spec.loader.exec_module(module)
    return module


def test_extract_edit_chain_from_fixture(repo_root, fixture_messages):
    module = _load_module(repo_root)
    messages = module.find_edited_messages(
        db_path=fixture_messages / "chat.db",
        since_ns=None,
        limit=10,
    )
    assert len(messages) == 1
    msg = messages[0]
    assert msg.rowid == 300
    assert msg.handle == "+15551234567"
    assert msg.current_text == "edit fixture v2: revised after typo"
    assert len(msg.versions) == 2

    v1, v2 = msg.versions
    assert v1.text == "edit fixture v1: original draft"
    assert v2.text == "edit fixture v2: revised after typo"
    assert v1.edited_at_ns < v2.edited_at_ns
    assert v1.raw_blob_len > 0 and v2.raw_blob_len > 0


def test_filter_by_rowid(repo_root, fixture_messages):
    module = _load_module(repo_root)
    messages = module.find_edited_messages(
        db_path=fixture_messages / "chat.db",
        rowid=300,
        since_ns=None,
    )
    assert len(messages) == 1
    assert messages[0].rowid == 300

    none = module.find_edited_messages(
        db_path=fixture_messages / "chat.db",
        rowid=999_999,
        since_ns=None,
    )
    assert none == []


def test_filter_by_handle(repo_root, fixture_messages):
    module = _load_module(repo_root)
    messages = module.find_edited_messages(
        db_path=fixture_messages / "chat.db",
        handle="+15551234567",
        since_ns=None,
    )
    assert len(messages) == 1

    none = module.find_edited_messages(
        db_path=fixture_messages / "chat.db",
        handle="+19999999999",
        since_ns=None,
    )
    assert none == []


def test_decode_typedstream_string_handles_empty(repo_root):
    """The decoder must not raise on empty / malformed BLOBs."""
    module = _load_module(repo_root)
    assert module.decode_typedstream_string(b"") is None
    assert module.decode_typedstream_string(b"random bytes with no marker") is None
    truncated = b"\x94\x84\x01\x2b\x05ab"
    assert module.decode_typedstream_string(truncated) is None or isinstance(
        module.decode_typedstream_string(truncated), str
    )


def test_json_cli_path(repo_root, fixture_messages):
    """End-to-end: invoke the script as a subprocess in --json mode."""
    result = subprocess.run(
        [
            sys.executable,
            str(repo_root / "scripts" / "edit-history.py"),
            "--db",
            str(fixture_messages / "chat.db"),
            "--since",
            "all",
            "--json",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    assert isinstance(payload, list)
    assert len(payload) == 1
    msg = payload[0]
    assert msg["rowid"] == 300
    assert msg["current_text"] == "edit fixture v2: revised after typo"
    versions = msg["versions"]
    assert len(versions) == 2
    assert versions[0]["text"] == "edit fixture v1: original draft"
    assert versions[1]["text"] == "edit fixture v2: revised after typo"
    assert versions[0]["edited_at_ns"] < versions[1]["edited_at_ns"]


def test_readonly_invariant(repo_root, fixture_messages):
    """The tool must not mutate chat.db. Compare bytes before/after."""
    db = fixture_messages / "chat.db"
    before = db.read_bytes()
    subprocess.run(
        [
            sys.executable,
            str(repo_root / "scripts" / "edit-history.py"),
            "--db",
            str(db),
            "--since",
            "all",
            "--json",
        ],
        check=True,
        capture_output=True,
    )
    after = db.read_bytes()
    assert before == after
