"""Tests for `scripts/lib/wal_extract.py` — the WAL byte-forensics core.

These exercise the GUID-adjacent text scan against fully synthetic byte
buffers (no real SQLite WAL, no real message content). The layout mirrors the
real one documented in docs/recovery-vectors.md § Vector 4:

    [pad] [36-byte GUID] [record-header control bytes] [inline UTF-8 text]
    [\\x04\\x0bstreamtyped = next column's marker] [pad]

The focus is the long-message window regression (#110): the original 512-byte
scan window silently dropped any message whose terminator landed further out.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

GUID = "00000000-0000-0000-0000-0000000000AA"  # 36 bytes, synthetic
# One control byte stands in for the SQLite record header between the GUID and
# the inline text; extract_candidates strips leading control bytes.
HEADER = b"\x06"


def _load_module(repo_root: Path):
    script = repo_root / "scripts" / "lib" / "wal_extract.py"
    spec = importlib.util.spec_from_file_location("imu_wal_extract", script)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["imu_wal_extract"] = module
    spec.loader.exec_module(module)
    return module


def _record(mod, text: str, *, pad_before: bytes = b"\x00\x10", pad_after: bytes = b"\xff\xff") -> bytes:
    return pad_before + GUID.encode("ascii") + HEADER + text.encode("utf-8") + mod.TYPEDSTREAM_MARKER + pad_after


def _write(tmp_path: Path, data: bytes) -> Path:
    wal = tmp_path / "chat.db-wal"
    wal.write_bytes(data)
    return wal


def test_short_message_recovered(repo_root, tmp_path):
    mod = _load_module(repo_root)
    wal = _write(tmp_path, _record(mod, "hello world"))
    results = mod.extract_candidates(wal, GUID)
    assert [text for _, text in results] == ["hello world"]


def test_message_near_old_boundary_recovered(repo_root, tmp_path):
    """~480 chars — around where record overhead pushed the terminator past 512."""
    mod = _load_module(repo_root)
    text = "N" * 480
    wal = _write(tmp_path, _record(mod, text))
    results = mod.extract_candidates(wal, GUID)
    assert [t for _, t in results] == [text]


def test_long_message_beyond_old_window_recovered(repo_root, tmp_path):
    """The core #110 regression: 600 chars was dropped by the 512 window."""
    mod = _load_module(repo_root)
    text = "B" * 600
    wal = _write(tmp_path, _record(mod, text))

    # Old behavior (explicit 512 window): terminator beyond window -> dropped.
    old = mod.extract_candidates(wal, GUID, window=512, warn=False)
    assert old == []

    # New default window recovers the full message.
    new = mod.extract_candidates(wal, GUID)
    assert [t for _, t in new] == [text]
    assert len(new[0][1]) == 600


def test_marker_beyond_window_is_reported_not_silent(repo_root, tmp_path, capsys):
    mod = _load_module(repo_root)
    text = "C" * 300
    wal = _write(tmp_path, _record(mod, text))
    # Window too small for this message's terminator.
    results = mod.extract_candidates(wal, GUID, window=100)
    assert results == []
    err = capsys.readouterr().err
    assert "scan window" in err and "truncated" in err


def test_binary_after_guid_is_not_a_false_positive(repo_root, tmp_path, capsys):
    """A GUID hit followed by binary (no marker) must not extract text, and must
    not be misreported as a truncated long message."""
    mod = _load_module(repo_root)
    binary_tail = bytes(range(256)) * 40  # 10 KB of non-text bytes, no marker
    wal = _write(tmp_path, b"\x00" + GUID.encode("ascii") + binary_tail)
    results = mod.extract_candidates(wal, GUID)
    assert results == []
    assert "truncated" not in capsys.readouterr().err


def test_empty_text_between_guid_and_marker_skipped(repo_root, tmp_path):
    mod = _load_module(repo_root)
    wal = _write(tmp_path, b"\x00" + GUID.encode("ascii") + mod.TYPEDSTREAM_MARKER + b"\xff")
    assert mod.extract_candidates(wal, GUID) == []


def test_duplicate_frames_deduplicated(repo_root, tmp_path):
    mod = _load_module(repo_root)
    # Same GUID + text appearing in two WAL frames collapses to one candidate.
    data = _record(mod, "unsent secret") + b"\x00" * 8 + _record(mod, "unsent secret")
    results = mod.extract_candidates(_write(tmp_path, data), GUID)
    assert [t for _, t in results] == ["unsent secret"]


def test_utf8_multibyte_recovered(repo_root, tmp_path):
    mod = _load_module(repo_root)
    text = "café ☃ 日本語 " * 20  # multibyte, > 100 bytes
    wal = _write(tmp_path, _record(mod, text))
    results = mod.extract_candidates(wal, GUID)
    assert [t for _, t in results] == [text]


def test_no_guid_hit_returns_empty(repo_root, tmp_path):
    mod = _load_module(repo_root)
    wal = _write(tmp_path, b"nothing to see here" * 100)
    assert mod.extract_candidates(wal, GUID) == []


def test_cli_json_path_with_window(repo_root, tmp_path):
    import json
    import subprocess

    mod = _load_module(repo_root)
    text = "D" * 600
    wal = _write(tmp_path, _record(mod, text))
    result = subprocess.run(
        [
            sys.executable,
            str(repo_root / "scripts" / "lib" / "wal_extract.py"),
            "--json",
            str(wal),
            GUID,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    assert len(payload) == 1
    assert payload[0]["length"] == 600
    assert payload[0]["text"] == text


def test_cli_rejects_nonpositive_window(repo_root, tmp_path):
    import subprocess

    wal = _write(tmp_path, b"x")
    result = subprocess.run(
        [
            sys.executable,
            str(repo_root / "scripts" / "lib" / "wal_extract.py"),
            "--window",
            "0",
            str(wal),
            GUID,
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "--window" in result.stderr
