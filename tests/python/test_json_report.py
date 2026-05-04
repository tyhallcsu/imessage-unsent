import json
import subprocess
import sys
from pathlib import Path


def _run_json_report(repo_root: Path, work: Path, failure_category: str = "") -> dict:
    msi = work / "msi.bin"
    ab = work / "ab.bin"
    wal_json = work / "wal-candidates.json"
    iphone_json = work / "iphone-backup.json"
    msi.write_bytes(b"")
    ab.write_bytes(b"")
    wal_json.write_text("[]")
    iphone_json.write_text(json.dumps({"enabled": False, "hit": False, "reason": "not requested"}))

    args = [
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
    completed = subprocess.run(args, check=True, capture_output=True, text=True)
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

    args = [
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
        "--failure-category", "wal_checkpointed",
    ]
    completed = subprocess.run(args, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    assert payload["recovered"]["text_b64"] == "aGVsbG8="
    assert "failure_category" not in payload["recovered"]
