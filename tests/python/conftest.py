from pathlib import Path
import shutil

import pytest


@pytest.fixture()
def repo_root():
    return Path(__file__).resolve().parents[2]


@pytest.fixture()
def fixture_messages(tmp_path, repo_root):
    messages = tmp_path / "Messages"
    messages.mkdir()
    fixture_dir = repo_root / "tests" / "fixtures"
    shutil.copy2(fixture_dir / "chat.db", messages / "chat.db")
    shutil.copy2(fixture_dir / "chat.db-wal", messages / "chat.db-wal")
    (messages / "chat.db-shm").touch()
    return messages
