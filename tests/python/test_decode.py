import plistlib
import sqlite3
import subprocess
import sys


def test_decode_reports_fixture_message_summary_info(repo_root, fixture_messages, tmp_path):
    connection = sqlite3.connect(fixture_messages / "chat.db")
    try:
        row = connection.execute(
            "SELECT message_summary_info FROM message WHERE ROWID = 200"
        ).fetchone()
    finally:
        connection.close()

    assert row is not None
    msi = row[0]
    plist = plistlib.loads(msi)
    assert plist["rp"] == [0]
    assert plist["otr"]["0"]["le"] == 42
    assert plist["ust"] is True

    ab_path = tmp_path / "ab.bin"
    msi_path = tmp_path / "msi.bin"
    ab_path.write_bytes(b"")
    msi_path.write_bytes(msi)

    result = subprocess.run(
        [sys.executable, str(repo_root / "scripts" / "decode.py"), str(ab_path), str(msi_path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    assert "rp (retracted parts): [0]" in result.stdout
    assert "otr (original text ranges): {'0': {'le': 42, 'lo': 0}}" in result.stdout
    assert "ust (user-sent text marker): True" in result.stdout
