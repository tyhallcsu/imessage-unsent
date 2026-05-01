#!/usr/bin/env bash
# Build a deterministic synthetic Messages database family for tests.

set -euo pipefail

OUT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/chat.db" "$OUT_DIR/chat.db-wal" "$OUT_DIR/chat.db-shm"

python3 - "$OUT_DIR" <<'PY'
import os
import plistlib
import sqlite3
import sys
import time
from pathlib import Path

out_dir = Path(sys.argv[1])
db_path = out_dir / "chat.db"
fixture_text = "Recovered fixture message: hello WAL data!"
assert len(fixture_text) == 42

writer = sqlite3.connect(db_path)
writer.execute("PRAGMA journal_mode=WAL;")
writer.execute("PRAGMA wal_autocheckpoint=0;")
writer.executescript(
    """
    CREATE TABLE handle (
      ROWID INTEGER PRIMARY KEY,
      id TEXT NOT NULL,
      service TEXT
    );
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY,
      guid TEXT,
      chat_identifier TEXT,
      display_name TEXT,
      service_name TEXT
    );
    CREATE TABLE chat_handle_join (
      chat_id INTEGER NOT NULL,
      handle_id INTEGER NOT NULL
    );
    CREATE TABLE chat_message_join (
      chat_id INTEGER NOT NULL,
      message_id INTEGER NOT NULL,
      message_date INTEGER
    );
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      guid TEXT NOT NULL,
      text TEXT,
      attributedBody BLOB,
      service TEXT,
      account TEXT,
      handle_id INTEGER,
      date INTEGER,
      date_read INTEGER,
      date_delivered INTEGER,
      date_edited INTEGER,
      date_retracted INTEGER,
      is_empty INTEGER,
      is_from_me INTEGER,
      is_delivered INTEGER,
      message_summary_info BLOB,
      payload_data BLOB,
      associated_message_guid TEXT
    );
    """
)

handle = "+15551234567"
writer.execute("INSERT INTO handle (ROWID, id, service) VALUES (1, ?, 'iMessage')", (handle,))
writer.execute(
    "INSERT INTO chat (ROWID, guid, chat_identifier, display_name, service_name) VALUES (1, 'chat-fixture', ?, NULL, 'iMessage')",
    (handle,),
)
writer.execute("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1)")

base_date = 797000000000000000
for idx in range(3):
    rowid = 100 + idx
    writer.execute(
        """
        INSERT INTO message
          (ROWID, guid, text, attributedBody, service, account, handle_id, date,
           date_read, date_delivered, date_edited, date_retracted, is_empty,
           is_from_me, is_delivered, message_summary_info)
        VALUES (?, ?, ?, ?, 'iMessage', 'fixture@example.com', 1, ?, 0, 0, 0, 0, 0, 0, 1, NULL)
        """,
        (rowid, f"fixture-normal-{idx}", f"normal fixture message {idx}", b"\x04\x0bstreamtyped", base_date + idx),
    )
    writer.execute("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, ?, ?)", (rowid, base_date + idx))

target_rowid = 200
guid = "fixture-retracted-guid-000000000001"
sent_at = base_date + 10
writer.execute(
    """
    INSERT INTO message
      (ROWID, guid, text, attributedBody, service, account, handle_id, date,
       date_read, date_delivered, date_edited, date_retracted, is_empty,
       is_from_me, is_delivered, message_summary_info)
    VALUES (?, ?, ?, ?, 'iMessage', 'fixture@example.com', 1, ?, 0, 0, 0, 0, 0, 0, 1, NULL)
    """,
    (target_rowid, guid, fixture_text, b"\x04\x0bstreamtyped", sent_at),
)
writer.execute("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, ?, ?)", (target_rowid, sent_at))
writer.commit()

reader = sqlite3.connect(db_path)
reader.execute("BEGIN")
reader.execute("SELECT text FROM message WHERE ROWID = ?", (target_rowid,)).fetchone()

msi = plistlib.dumps(
    {"amc": 0, "otr": {"0": {"le": len(fixture_text), "lo": 0}}, "rp": [0], "ust": True},
    fmt=plistlib.FMT_BINARY,
)
writer.execute(
    """
    UPDATE message
    SET text = NULL,
        attributedBody = X'',
        is_empty = 1,
        date_edited = ?,
        message_summary_info = ?
    WHERE ROWID = ?
    """,
    (sent_at + 30_000_000_000, msi, target_rowid),
)
writer.commit()

for suffix in ("-wal", "-shm"):
    path = Path(f"{db_path}{suffix}")
    for _ in range(20):
        if path.exists() and path.stat().st_size > 0:
            break
        time.sleep(0.05)

print(f"fixture_text={fixture_text}", flush=True)
os._exit(0)
PY
