import json
import plistlib
import subprocess
import sys
from pathlib import Path


def _json_report_args(repo_root: Path, work: Path, failure_category: str = "") -> list[str]:
    msi = work / "msi.bin"
    ab = work / "ab.bin"
    wal_json = work / "wal-candidates.json"
    iphone_json = work / "iphone-backup.json"
    if not msi.exists():
        msi.write_bytes(b"")
    if not ab.exists():
        ab.write_bytes(b"")
    if not wal_json.exists():
        wal_json.write_text("[]")
    if not iphone_json.exists():
        iphone_json.write_text(json.dumps({"enabled": False, "hit": False, "reason": "not requested"}))

    return [
        sys.executable,
        str(repo_root / "scripts" / "lib" / "json_report.py"),
        "--ran-at", "2026-05-04T00:00:00Z",
        "--handle", "+15555550100",
        "--chat-rowid", "12",
        "--rowid", "200",
        "--guid", "00000000-0000-0000-0000-000000000001",
        "--sent-at", "2026-05-04 00:00:00",
        "--edited-at", "2026-05-04 00:00:01",
        "--msi", str(msi),
        "--ab", str(ab),
        "--wal-json", str(wal_json),
        "--iphone-json", str(iphone_json),
        "--failure-category", failure_category,
    ]


def _run_json_report(repo_root: Path, work: Path, failure_category: str = "") -> dict:
    completed = subprocess.run(
        _json_report_args(repo_root, work, failure_category=failure_category),
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def test_emits_explicit_failure_category(repo_root, tmp_path):
    payload = _run_json_report(repo_root, tmp_path, failure_category="unknown_handle")
    assert payload["recovered"]["text_b64"] is None
    assert payload["recovered"]["failure_category"] == "unknown_handle"


def test_defaults_to_wal_checkpointed_when_empty(repo_root, tmp_path):
    payload = _run_json_report(repo_root, tmp_path, failure_category="")
    assert payload["recovered"]["failure_category"] == "wal_checkpointed"


def test_omits_failure_category_when_text_recovered(repo_root, tmp_path):
    msi = tmp_path / "msi.bin"
    ab = tmp_path / "ab.bin"
    wal_json = tmp_path / "wal-candidates.json"
    iphone_json = tmp_path / "iphone-backup.json"
    msi.write_bytes(b"")
    ab.write_bytes(b"")
    wal_json.write_text(json.dumps([{
        "offset": 4096,
        "length": 5,
        "text": "hello",
        "text_b64": "aGVsbG8=",
    }]))
    iphone_json.write_text(json.dumps({"enabled": False, "hit": False, "reason": "not requested"}))

    completed = subprocess.run(
        _json_report_args(repo_root, tmp_path, failure_category="wal_checkpointed"),
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(completed.stdout)
    assert payload["recovered"]["text_b64"] == "aGVsbG8="
    assert "failure_category" not in payload["recovered"]


def test_trims_selected_wal_text_to_msi_length(repo_root, tmp_path):
    msi = tmp_path / "msi.bin"
    wal_json = tmp_path / "wal-candidates.json"
    msi.write_bytes(plistlib.dumps({"otr": {"0": {"le": 7}}}))
    wal_json.write_text(json.dumps([{
        "offset": 512,
        "length": 8,
        "text": "SENDING<",
        "text_b64": "U0VORElORzw=",
    }]))

    payload = _run_json_report(repo_root, tmp_path, failure_category="")
    assert payload["candidate"]["msi_otr_le"] == 7
    assert payload["recovered"]["length"] == 7
    assert payload["recovered"]["trimmed_to_msi_length"] is True
    assert payload["recovered"]["text_b64"] == "U0VORElORw=="
    assert payload["vectors"]["wal"]["candidates"][0]["trimmed_to_msi_length"] is True


def test_placeholder_only_wal_hit_is_not_recovered(repo_root, tmp_path):
    wal_json = tmp_path / "wal-candidates.json"
    wal_json.write_text(json.dumps([{
        "offset": 1024,
        "length": 1,
        "text": "\uFFFC",
        "text_b64": "77+8",
    }]))

    payload = _run_json_report(repo_root, tmp_path, failure_category="")
    assert payload["vectors"]["wal"]["hit"] is True
    assert payload["vectors"]["wal"]["candidates"][0]["human_readable"] is False
    assert payload["recovered"]["text_b64"] is None
    assert payload["recovered"]["failure_category"] == "unknown"


def test_uses_iphone_backup_when_wal_hit_is_not_human_readable(repo_root, tmp_path):
    wal_json = tmp_path / "wal-candidates.json"
    iphone_json = tmp_path / "iphone-backup.json"
    wal_json.write_text(json.dumps([{
        "offset": 1024,
        "length": 1,
        "text": "\uFFFC",
        "text_b64": "77+8",
    }]))
    iphone_json.write_text(json.dumps({
        "enabled": True,
        "hit": True,
        "reason": "matched backup",
        "text_b64": "aGVsbG8=",
        "length": 5,
    }))

    payload = _run_json_report(repo_root, tmp_path, failure_category="")
    assert payload["recovered"]["source"] == "iphone_backup"
    assert payload["recovered"]["text_b64"] == "aGVsbG8="
    assert "failure_category" not in payload["recovered"]
