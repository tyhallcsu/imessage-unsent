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


# SQLite stamps the library version that last wrote a database into its header
# at offset 96 (`SQLITE_VERSION_NUMBER`). That single field is the whole reason
# the checked-in fixture used to churn: rebuilding on a machine with a
# different SQLite rewrote 2 bytes and left the tree dirty (issue #165).
#
# Pinning it to a frozen constant makes the fixture reproducible across SQLite
# versions — verified byte-identical between 3.41.2 and 3.53.3. The field is
# informational; SQLite does not validate it against the running library.
#
# `version_valid_for` (offset 92) is deliberately left alone: it tracks the
# change counter rather than the library, and has been stable across every
# version observed. Pinning only what actually drifts keeps the fixture honest.
FIXTURE_SQLITE_VERSION = 3_051_000
SQLITE_VERSION_OFFSET = 96


def normalize_sqlite_header(db_path):
    """Freeze the SQLite version stamp in a database file header."""
    with open(db_path, "r+b") as handle:
        handle.seek(SQLITE_VERSION_OFFSET)
        handle.write(struct.pack(">I", FIXTURE_SQLITE_VERSION))


def normalize_wal_page_one_frames(wal_path):
    """Freeze the version stamp in every page-1 image inside the WAL.

    Page 1 carries the 100-byte database header, and the fixture's WAL holds
    five separate copies of it. Normalizing only chat.db would leave those
    copies drifting. Must run BEFORE normalize_wal(), which recomputes the
    frame checksums this invalidates.
    """
    wal = bytearray(wal_path.read_bytes())
    if len(wal) < 32:
        return

    page_size = struct.unpack(">I", wal[8:12])[0]
    frame_size = 24 + page_size
    if (len(wal) - 32) % frame_size != 0:
        raise RuntimeError("WAL has an unexpected frame size")

    for offset in range(32, len(wal), frame_size):
        page_number = struct.unpack(">I", wal[offset : offset + 4])[0]
        if page_number != 1:
            continue
        stamp_at = offset + 24 + SQLITE_VERSION_OFFSET
        wal[stamp_at : stamp_at + 4] = struct.pack(">I", FIXTURE_SQLITE_VERSION)

    wal_path.write_bytes(wal)


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


def build_attributedstring_typedstream(text):
    """Produce a minimal valid streamtyped NSAttributedString blob for plain text.

    Mirrors the on-the-wire format observed in chat.db `ec` entries:
      - `streamtyped` header + class chain for NSAttributedString
      - NSString init marker `\\x94\\x84\\x01\\x2b`
      - 1-byte length (we cap fixture text under 128 bytes)
      - UTF-8 string bytes
      - `\\x86` terminator + minimal NSDictionary attribute trailer
    """
    text_bytes = text.encode("utf-8")
    if len(text_bytes) >= 0x81:
        raise ValueError("fixture text must be < 128 UTF-8 bytes")
    header = (
        b"\x04\x0bstreamtyped\x81\xe8\x03"
        b"\x84\x01@"
        b"\x84\x84\x84\x12NSAttributedString\x00"
        b"\x84\x84\x08NSObject\x00\x85"
        b"\x92\x84\x84\x84\x08NSString\x01"
    )
    nsstring_payload = b"\x94\x84\x01\x2b" + bytes([len(text_bytes)]) + text_bytes + b"\x86"
    trailer = b"\x84\x02iI\x01" + bytes([len(text_bytes)]) + b"\x86\x86"
    return header + nsstring_payload + trailer


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

    # Before the utime pass below — writing to the files afterwards would undo
    # the deterministic mtimes.
    normalize_sqlite_header(manifest_path)
    normalize_sqlite_header(sms_path)

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
      is_read INTEGER,
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
           is_from_me, is_read, is_delivered, message_summary_info)
        VALUES (?, ?, ?, ?, 'iMessage', 'fixture@example.com', 1, ?, 0, 0, 0, 0, 0, 0, 0, 1, NULL)
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
       is_from_me, is_read, is_delivered, message_summary_info)
    VALUES (?, ?, ?, ?, 'iMessage', 'fixture@example.com', 1, ?, 0, 0, 0, 0, 0, 0, 0, 1, NULL)
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

edit_rowid = 300
edit_guid = "00000000-0000-0000-0000-000000000300"
edit_sent_at = base_date + 100
edit_v1_text = "edit fixture v1: original draft"
edit_v2_text = "edit fixture v2: revised after typo"
edit_v1_apple_real = (edit_sent_at) / 1_000_000_000
edit_v2_apple_real = edit_v1_apple_real + 7.5  # 7.5 s later
edit_msi = plistlib.dumps(
    {
        "amc": 1,
        "ec": {
            "0": [
                {"d": edit_v1_apple_real, "t": build_attributedstring_typedstream(edit_v1_text)},
                {"d": edit_v2_apple_real, "t": build_attributedstring_typedstream(edit_v2_text)},
            ],
        },
        "ep": [0],
        "otr": {"0": {"le": len(edit_v2_text), "lo": 0}},
        "ust": True,
    },
    fmt=plistlib.FMT_BINARY,
)
edit_date_edited = edit_sent_at + int(7.5 * 1_000_000_000)
writer.execute(
    """
    INSERT INTO message
      (ROWID, guid, text, attributedBody, service, account, handle_id, date,
       date_read, date_delivered, date_edited, date_retracted, is_empty,
       is_from_me, is_read, is_delivered, message_summary_info)
    VALUES (?, ?, ?, ?, 'iMessage', 'fixture@example.com', 1, ?, 0, 0, ?, 0, 0, 0, 0, 1, ?)
    """,
    (
        edit_rowid,
        edit_guid,
        edit_v2_text,
        build_attributedstring_typedstream(edit_v2_text),
        edit_sent_at,
        edit_date_edited,
        edit_msi,
    ),
)
writer.execute(
    "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, ?, ?)",
    (edit_rowid, edit_sent_at),
)
writer.commit()

# --- Vector 8 (read receipts) rows -------------------------------------------
# Five rows covering every receipt state the classifier has to distinguish.
# `is_read`/`date_read` disagree on purpose: `flagged_only` (flag set, no
# timestamp) is the state Messages.app cannot express and the reason this
# vector exists. See docs/recovery-vectors.md.
receipt_base = base_date + 200
# ROWID 402 deliberately carries handle_id = 0: Messages leaves it unset on
# roughly half of all outgoing rows, so the counterparty has to be resolved
# through chat_message_join instead. A handle filter that misses this row
# would drop most outgoing traffic on a real chat.db.
receipt_rows = [
    # (rowid, guid-suffix, text, offset_s, service, is_from_me, handle_id,
    #  date_read_offset_s, is_read, date_delivered_offset_s, is_delivered)
    (400, "400", "receipt fixture: outgoing, read with timestamp",
     0, "iMessage", 1, 1, 65, 1, 2, 1),
    (401, "401", "receipt fixture: outgoing, read flag but no timestamp",
     10, "iMessage", 1, 1, None, 1, None, 1),
    (402, "402", "receipt fixture: outgoing, delivered but never read",
     20, "iMessage", 1, 0, None, 0, 3, 1),
    (403, "403", "receipt fixture: outgoing SMS, receipts unsupported",
     30, "SMS", 1, 1, None, 0, None, 0),
    (404, "404", "receipt fixture: incoming, read by me with timestamp",
     40, "iMessage", 0, 1, 12, 1, 1, 1),
]
for (
    r_rowid, r_suffix, r_text, r_offset, r_service, r_from_me, r_handle_id,
    r_read_off, r_is_read, r_delivered_off, r_is_delivered,
) in receipt_rows:
    r_sent = receipt_base + r_offset * 1_000_000_000
    r_read = r_sent + r_read_off * 1_000_000_000 if r_read_off is not None else 0
    r_delivered = (
        r_sent + r_delivered_off * 1_000_000_000 if r_delivered_off is not None else 0
    )
    writer.execute(
        """
        INSERT INTO message
          (ROWID, guid, text, attributedBody, service, account, handle_id, date,
           date_read, date_delivered, date_edited, date_retracted, is_empty,
           is_from_me, is_read, is_delivered, message_summary_info)
        VALUES (?, ?, ?, ?, ?, 'fixture@example.com', ?, ?, ?, ?, 0, 0, 0, ?, ?, ?, NULL)
        """,
        (
            r_rowid,
            f"00000000-0000-0000-0000-000000000{r_suffix}",
            r_text,
            build_attributedstring_typedstream(r_text),
            r_service,
            r_handle_id,
            r_sent,
            r_read,
            r_delivered,
            r_from_me,
            r_is_read,
            r_is_delivered,
        ),
    )
    writer.execute(
        "INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, ?, ?)",
        (r_rowid, r_sent),
    )
writer.commit()

build_iphone_backup_fixture(out_dir, handle, guid, fixture_text, sent_at)
normalize_sqlite_header(db_path)
# Order matters: patch the page-1 images first, then recompute WAL checksums.
normalize_wal_page_one_frames(Path(f"{db_path}-wal"))
normalize_wal(Path(f"{db_path}-wal"))
print(f"fixture_text={fixture_text}", flush=True)
print(f"edit_v1={edit_v1_text}", flush=True)
print(f"edit_v2={edit_v2_text}", flush=True)
os._exit(0)
PY
