import plistlib
import subprocess
from pathlib import Path


def test_fixture_message_summary_info_shape(tmp_path: Path) -> None:
    fixture_dir = tmp_path / "fixture"
    fixture_dir.mkdir()
    subprocess.run(["./tests/fixtures/build-fixture.sh", str(fixture_dir)], check=True)

    db = fixture_dir / "chat.db"
    msi = fixture_dir / "msi.bin"
    subprocess.run(
        [
            "sqlite3",
            "-readonly",
            str(db),
            f"SELECT writefile('{msi}', message_summary_info) FROM message WHERE ROWID=200;",
        ],
        check=True,
    )

    payload = plistlib.loads(msi.read_bytes())
    assert payload["rp"] == [0]
    assert payload["otr"]["0"]["le"] == 42
    assert payload["ust"] is True
