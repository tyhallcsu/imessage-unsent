#!/usr/bin/env python3
"""Recover prior versions of edited iMessages from chat.db.

When a sender edits a message (Apple's 15-minute / 5-edit window), every
prior version is preserved on the row in `message_summary_info` (msi) as a
typedstream-encoded `NSAttributedString`, with an Apple-absolute timestamp
per edit. This is distinct from the unsent/retraction recovery that
`recover.sh` handles via WAL byte-scan.

Read-only by design. Connects via SQLite URI in `mode=ro` and never writes
to `chat.db`.

Usage:
    python3 edit-history.py [--db PATH] [--handle E.164] [--rowid N]
                            [--since DURATION] [--json] [--limit N]

DURATION accepts e.g. `24h`, `7d`, `30d`, or a literal `all`.
Default `--db` is `~/Library/Messages/chat.db`.

Closes the gap documented in issue #106. The bash pipeline filters at
`is_empty = 1` (the retraction predicate) and so never reaches edited-but-
not-retracted rows; this tool inverts that filter and reports the `ec`
chain.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

APPLE_EPOCH_OFFSET = 978_307_200  # seconds between 1970-01-01 and 2001-01-01

# typedstream NSString-with-plain-text marker. The bytes that follow are:
#   <length-byte> <utf-8 bytes> ... \x86
# For lengths >= 0x81 the length itself is multi-byte; see _read_length.
NSSTRING_INIT_MARKER = b"\x94\x84\x01\x2b"


@dataclass
class EditVersion:
    """One revision in an `ec` chain."""
    part: str
    index: int
    edited_at_ns: int  # ns since UNIX epoch
    edited_at_iso: str
    text: str | None
    raw_blob_len: int


@dataclass
class EditedMessage:
    """A row in `message` with date_edited != 0 and is_empty = 0."""
    rowid: int
    guid: str
    handle: str | None
    sent_at_ns: int
    sent_at_iso: str
    edited_at_ns: int
    edited_at_iso: str
    current_text: str | None
    versions: list[EditVersion]


def _apple_ns_to_iso(ns: int | float) -> str:
    if ns is None:
        return ""
    seconds = ns / 1_000_000_000 + APPLE_EPOCH_OFFSET
    return datetime.fromtimestamp(seconds, tz=timezone.utc).astimezone().strftime(
        "%Y-%m-%d %H:%M:%S %Z"
    )


def _apple_ns_to_unix_ns(ns: int) -> int:
    return ns + APPLE_EPOCH_OFFSET * 1_000_000_000


def _real_apple_to_unix_ns(real: float) -> int:
    return int((real + APPLE_EPOCH_OFFSET) * 1_000_000_000)


def _read_length(data: bytes, pos: int) -> tuple[int, int]:
    """Decode a typedstream length prefix. Returns (length, new_pos)."""
    if pos >= len(data):
        return -1, pos
    head = data[pos]
    pos += 1
    if head < 0x81:
        return head, pos
    if head == 0x81:
        if pos + 2 > len(data):
            return -1, pos
        return int.from_bytes(data[pos:pos + 2], "little"), pos + 2
    if head == 0x82:
        if pos + 4 > len(data):
            return -1, pos
        return int.from_bytes(data[pos:pos + 4], "little"), pos + 4
    return -1, pos


def decode_typedstream_string(blob: bytes) -> str | None:
    """Pull the NSString payload out of an NSAttributedString typedstream blob.

    Doesn't require the optional `typedstream` Python module — uses a stable
    byte pattern (`\\x94\\x84\\x01\\x2b <length> <utf-8> \\x86`) that holds for
    plain-text messages on Sequoia / Darwin 24.x. Returns None if the marker
    isn't present (e.g. attachments, certain rich-text edits).
    """
    if not blob:
        return None
    idx = blob.find(NSSTRING_INIT_MARKER)
    if idx < 0:
        return None
    pos = idx + len(NSSTRING_INIT_MARKER)
    length, pos = _read_length(blob, pos)
    if length < 0 or pos + length > len(blob):
        return _fallback_extract(blob, idx)
    return blob[pos:pos + length].decode("utf-8", errors="replace")


def _fallback_extract(blob: bytes, anchor: int) -> str | None:
    """Last-resort: longest UTF-8 run between NSString marker and \\x86."""
    end = blob.find(b"\x86", anchor)
    if end < 0:
        end = len(blob)
    segment = blob[anchor + len(NSSTRING_INIT_MARKER):end]
    runs = re.findall(rb"[\x20-\x7e\xc2-\xfd][\x20-\x7e\x80-\xfd]{2,}", segment)
    runs = [r for r in runs if b"NSString" not in r and b"NSDictionary" not in r]
    if not runs:
        return None
    longest = max(runs, key=len)
    text = re.sub(rb"^[^A-Za-z\xc0-\xff]+", b"", longest)
    try:
        return text.decode("utf-8", errors="replace")
    except UnicodeDecodeError:
        return None


def parse_ec_chain(msi_bytes: bytes) -> list[EditVersion]:
    """Parse `ec` array out of the message_summary_info bplist."""
    if not msi_bytes:
        return []
    try:
        plist = plistlib.loads(msi_bytes)
    except (plistlib.InvalidFileException, ValueError):
        return []
    ec = plist.get("ec") if isinstance(plist, dict) else None
    if not ec:
        return []

    out: list[EditVersion] = []
    items: Iterable
    if isinstance(ec, dict):
        items = ec.items()
    else:
        items = enumerate(ec)
    for part_key, versions in items:
        if not isinstance(versions, list):
            continue
        part = str(part_key)
        for i, entry in enumerate(versions):
            if not isinstance(entry, dict):
                continue
            blob = entry.get("t") or entry.get("text")
            ts_real = entry.get("d") or entry.get("date")
            edited_ns = _real_apple_to_unix_ns(float(ts_real)) if ts_real is not None else 0
            edited_iso = _apple_ns_to_iso(int(float(ts_real) * 1_000_000_000)) if ts_real is not None else ""
            text = decode_typedstream_string(blob) if isinstance(blob, (bytes, bytearray)) else None
            out.append(
                EditVersion(
                    part=part,
                    index=i,
                    edited_at_ns=edited_ns,
                    edited_at_iso=edited_iso,
                    text=text,
                    raw_blob_len=len(blob) if isinstance(blob, (bytes, bytearray)) else 0,
                )
            )
    out.sort(key=lambda v: (v.part, v.edited_at_ns, v.index))
    return out


def _parse_since(value: str) -> int | None:
    """Convert `--since` to nanoseconds-from-now. Returns None for `all`."""
    if value.lower() in ("all", "any", ""):
        return None
    m = re.fullmatch(r"(\d+)([smhd])", value.strip().lower())
    if not m:
        raise SystemExit(f"--since: bad duration {value!r} (expected e.g. 24h, 7d, all)")
    n = int(m.group(1))
    units = {"s": 1, "m": 60, "h": 3_600, "d": 86_400}
    return n * units[m.group(2)] * 1_000_000_000


def _connect_readonly(path: Path) -> sqlite3.Connection:
    if not path.exists():
        raise SystemExit(f"chat.db not found: {path}")
    uri = f"file:{path}?mode=ro"
    return sqlite3.connect(uri, uri=True)


def find_edited_messages(
    db_path: Path,
    handle: str | None = None,
    rowid: int | None = None,
    since_ns: int | None = None,
    limit: int = 50,
) -> list[EditedMessage]:
    conn = _connect_readonly(db_path)
    try:
        clauses = ["m.date_edited != 0", "m.is_empty = 0"]
        params: list[object] = []
        if rowid is not None:
            clauses.append("m.ROWID = ?")
            params.append(rowid)
        if handle is not None:
            clauses.append("h.id = ?")
            params.append(handle)
        if since_ns is not None:
            now_ns = int(datetime.now(tz=timezone.utc).timestamp() * 1_000_000_000)
            cutoff_apple_ns = now_ns - since_ns - APPLE_EPOCH_OFFSET * 1_000_000_000
            clauses.append("m.date_edited >= ?")
            params.append(cutoff_apple_ns)
        where = " AND ".join(clauses)
        sql = f"""
            SELECT m.ROWID, m.guid, h.id AS handle,
                   m.date, m.date_edited, m.text, m.message_summary_info
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE {where}
            ORDER BY m.date_edited DESC
            LIMIT ?
        """
        params.append(limit)
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()

    out: list[EditedMessage] = []
    for rowid_, guid, h, date_ns, edited_ns, text, msi in rows:
        versions = parse_ec_chain(msi or b"")
        out.append(
            EditedMessage(
                rowid=rowid_,
                guid=guid,
                handle=h,
                sent_at_ns=_apple_ns_to_unix_ns(date_ns or 0),
                sent_at_iso=_apple_ns_to_iso(date_ns or 0),
                edited_at_ns=_apple_ns_to_unix_ns(edited_ns or 0),
                edited_at_iso=_apple_ns_to_iso(edited_ns or 0),
                current_text=text,
                versions=versions,
            )
        )
    return out


def render_text(messages: list[EditedMessage]) -> str:
    if not messages:
        return "No edited messages found.\n"
    lines: list[str] = []
    for msg in messages:
        lines.append("=" * 72)
        lines.append(f"ROWID {msg.rowid}  GUID {msg.guid}")
        lines.append(f"  handle    : {msg.handle or '(none)'}")
        lines.append(f"  sent      : {msg.sent_at_iso}")
        lines.append(f"  edited    : {msg.edited_at_iso}")
        lines.append(f"  current   : {msg.current_text!r}")
        if not msg.versions:
            lines.append("  ec chain  : (none — msi has no edit chronology for this row)")
            continue
        lines.append(f"  ec chain  : {len(msg.versions)} version(s)")
        for v in msg.versions:
            lines.append(
                f"    part={v.part} v{v.index + 1} @ {v.edited_at_iso}  "
                f"({v.raw_blob_len} bytes)"
            )
            lines.append(f"      text: {v.text!r}")
    lines.append("")
    return "\n".join(lines)


def render_json(messages: list[EditedMessage]) -> str:
    payload = []
    for msg in messages:
        payload.append({
            "rowid": msg.rowid,
            "guid": msg.guid,
            "handle": msg.handle,
            "sent_at_ns": msg.sent_at_ns,
            "sent_at_iso": msg.sent_at_iso,
            "edited_at_ns": msg.edited_at_ns,
            "edited_at_iso": msg.edited_at_iso,
            "current_text": msg.current_text,
            "versions": [
                {
                    "part": v.part,
                    "index": v.index,
                    "edited_at_ns": v.edited_at_ns,
                    "edited_at_iso": v.edited_at_iso,
                    "text": v.text,
                    "raw_blob_len": v.raw_blob_len,
                }
                for v in msg.versions
            ],
        })
    return json.dumps(payload, ensure_ascii=False, indent=2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Recover prior versions of edited iMessages from chat.db.",
        epilog="See docs/recovery-vectors.md for the underlying technique.",
    )
    parser.add_argument(
        "--db",
        default=os.path.expanduser("~/Library/Messages/chat.db"),
        help="path to chat.db (default: ~/Library/Messages/chat.db)",
    )
    parser.add_argument("--handle", help="filter by E.164 phone or Apple ID email")
    parser.add_argument("--rowid", type=int, help="filter by message.ROWID")
    parser.add_argument(
        "--since",
        default="7d",
        help="recency window (e.g. 24h, 7d, 30d, or 'all'); default: 7d",
    )
    parser.add_argument("--limit", type=int, default=50, help="max rows to inspect (default: 50)")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = parser.parse_args(argv)

    since_ns = _parse_since(args.since)
    messages = find_edited_messages(
        db_path=Path(args.db),
        handle=args.handle,
        rowid=args.rowid,
        since_ns=since_ns,
        limit=args.limit,
    )
    if args.json:
        sys.stdout.write(render_json(messages) + "\n")
    else:
        sys.stdout.write(render_text(messages))
    return 0


if __name__ == "__main__":
    sys.exit(main())
