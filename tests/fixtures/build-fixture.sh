#!/usr/bin/env bash
# Build a deterministic synthetic Messages database family for tests.

set -euo pipefail

OUT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/chat.db" "$OUT_DIR/chat.db-wal" "$OUT_DIR/chat.db-shm"

python3 - "$OUT_DIR" <<'PY'
import os
import plistlib
import shutil
import sqlite3
import sys
import time
import struct
from pathlib import Path

out_dir = Path(sys.argv[1])
db_path = out_dir / "chat.db"
fixture_text = "Recovered fixture message: hello WAL data!"
assert len(fixture_text) == 42


def wal_checksum(data, endian, s0=0, s1=0):
    for index in range(0, len(data), 8):
        word0, word1 = struct.unpack(f"{endian}II", data[index : index + 8])
        s0 = (s0 + word0 + s1) & 0xFFFFFFFF
        s1 = (s1 + word1 + s0) & 0xFFFFFFFF
    return s0, s1


def checksum_endian(wal):
    stored = struct.unpack(">II", wal[24:32])
    for endian in ("<", ">"):
        if wal_checksum(wal[:24], endian) == stored:
            return endian
    raise RuntimeError("could not infer WAL checksum byte order")


def normalize_wal(wal_path):
    wal = bytearray(wal_path.read_bytes())
    if len(wal) < 32:
        raise RuntimeError("WAL is too small")

    page_size = struct.unpack(">I", wal[8:12])[0]
    frame_size = 24 + page_size
    if (len(wal) - 32) % frame_size != 0:
        raise RuntimeError("WAL has an unexpected frame size")

    endian = checksum_endian(wal)
    salt1 = 0x494D5531  # IMU1
    salt2 = 0x46495831  # FIX1
    wal[12:16] = struct.pack(">I", 0)
    wal[16:24] = struct.pack(">II", salt1, salt2)

    s0, s1 = wal_checksum(wal[:24], endian)
    wal[24:32] = struct.pack(">II", s0, s1)

    for offset in range(32, len(wal), frame_size):
        wal[offset + 8 : offset + 16] = struct.pack(">II", salt1, salt2)
        frame_payload = wal[offset : offset + 8] + wal[offset + 24 : offset + frame_size]
        s0, s1 = wal_checksum(frame_payload, endian, s0, s1)
        wal[offset + 16 : offset + 24] = struct.pack(">II", s0, s1)

    wal_path.write_bytes(wal)


def build_iphone_backup_fixture(out_dir, handle, guid, fixture_text, sent_at):
    backup_root = out_dir / "iphone-backup"
    file_id = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"
    sms_path = backup_root / file_id[:2] / file_id
    manifest_path = backup_root / "Manifest.db"

    shutil.rmtree(backup_root, ignore_errors=True)
    sms_path.parent.mkdir(parents=True)

    manifest = sqlite3.connect(manifest_path)
    manifest.execute(
        """
        CREATE TABLE Files (
          fileID TEXT PRIMARY KEY,
          domain TEXT NOT NULL,
          relativePath TEXT NOT NULL
        )
        """
    )
    manifest.execute(
        "INSERT INTO Files (fileID, domain, relativePath) VALUES (?, 'HomeDomain', 'Library/SMS/sms.db')",
        (file_id,),
    )
    manifest.commit()
    manifest.close()

    sms = sqlite3.connect(sms_path)
    sms.executescript(
        """
        CREATE TABLE handle (
          ROWID INTEGER PRIMARY KEY,
          id TEXT NOT NULL,
          service TEXT
        );
        CREATE TABLE message (
          ROWID INTEGER PRIMARY KEY,
          guid TEXT NOT NULL,
          text TEXT,
          service TEXT,
          account TEXT,
          handle_id INTEGER,
          date INTEGER,
          is_from_me INTEGER
        );
        """
    )
    sms.execute("INSERT INTO handle (ROWID, id, service) VALUES (1, ?, 'iMessage')", (handle,))
    sms.execute(
        """
        INSERT INTO message
          (ROWID, guid, text, service, account, handle_id, date, is_from_me)
        VALUES (200, ?, ?, 'iMessage', 'fixture@example.com', 1, ?, 0)
        """,
        (guid, fixture_text, sent_at),
    )
    sms.commit()
    sms.close()

    backup_unix_time = int((sent_at / 1_000_000_000) + 978_307_200 + 10)
    for path in (backup_root, manifest_path, sms_path):
        os.utime(path, (backup_unix_time, backup_unix_time))

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
    writer.execute(
        "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, ?, ?)",
        (rowid, base_date + idx),
    )

target_rowid = 200
guid = "00000000-0000-0000-0000-000000000001"
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

build_iphone_backup_fixture(out_dir, handle, guid, fixture_text, sent_at)
normalize_wal(Path(f"{db_path}-wal"))
print(f"fixture_text={fixture_text}", flush=True)
os._exit(0)
PY
