#!/usr/bin/env python3
"""Recover a candidate message from an unencrypted iPhone backup sms.db."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sqlite3
from pathlib import Path
from typing import Any


APPLE_EPOCH_OFFSET = 978_307_200
SMS_RELATIVE_PATH = "Library/SMS/sms.db"
SMS_FILE_ID = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"


def apple_ns_to_unix_seconds(value: int) -> float:
    return (value / 1_000_000_000) + APPLE_EPOCH_OFFSET


def connect_readonly(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def config_paths(config_path: Path) -> list[Path]:
    if not config_path.exists():
        return []

    paths: list[Path] = []
    for raw in config_path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        paths.append(Path(os.path.expanduser(line)))
    return paths


def default_backup_roots(home: Path, config_path: Path) -> list[Path]:
    roots: list[Path] = []
    mobile_sync = home / "Library" / "Application Support" / "MobileSync" / "Backup"
    if mobile_sync.exists():
        roots.extend(sorted(path for path in mobile_sync.iterdir() if path.is_dir()))
    roots.extend(config_paths(config_path))
    return roots


def manifest_mtime(path: Path) -> float | None:
    manifest = path / "Manifest.db"
    if manifest.exists():
        return manifest.stat().st_mtime
    if path.exists():
        return path.stat().st_mtime
    return None


def resolve_sms_db(path: Path) -> tuple[Path | None, str, str | None]:
    if path.is_file():
        return path, "direct", None

    loose = path / SMS_RELATIVE_PATH
    if loose.exists():
        return loose, "loose", None

    manifest = path / "Manifest.db"
    if manifest.exists():
        try:
            with connect_readonly(manifest) as connection:
                row = connection.execute(
                    """
                    SELECT fileID
                    FROM Files
                    WHERE relativePath = ?
                    ORDER BY CASE WHEN domain = 'HomeDomain' THEN 0 ELSE 1 END
                    LIMIT 1
                    """,
                    (SMS_RELATIVE_PATH,),
                ).fetchone()
        except sqlite3.DatabaseError as error:
            return None, "manifest", f"could not read Manifest.db: {error}"
        if row and row[0]:
            file_id = str(row[0])
            return path / file_id[:2] / file_id, "manifest", None

    fallback = path / SMS_FILE_ID[:2] / SMS_FILE_ID
    if fallback.exists():
        return fallback, "fixed-file-id", None

    return None, "missing", "could not locate Library/SMS/sms.db in backup"


def readable_sqlite(path: Path) -> tuple[bool, str | None]:
    if not path.exists():
        return False, "sms.db file is missing"
    with path.open("rb") as handle:
        header = handle.read(16)
    if header != b"SQLite format 3\x00":
        return (
            False,
            "sms.db is not a readable SQLite database; encrypted backups must be decrypted first",
        )
    return True, None


def recover_from_sms_db(db_path: Path, guid: str, handle: str) -> dict[str, Any]:
    ok, reason = readable_sqlite(db_path)
    if not ok:
        return {"hit": False, "reason": reason}

    try:
        with connect_readonly(db_path) as connection:
            row = connection.execute(
                """
                SELECT m.ROWID, m.guid, m.text, m.date, h.id
                FROM message m
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE m.guid = ?
                   OR (h.id = ? AND m.is_from_me = 0)
                ORDER BY CASE WHEN m.guid = ? THEN 0 ELSE 1 END, m.date DESC
                LIMIT 1
                """,
                (guid, handle, guid),
            ).fetchone()
    except sqlite3.DatabaseError as error:
        return {
            "hit": False,
            "reason": f"could not query sms.db; encrypted backups must be decrypted first: {error}",
        }

    if not row:
        return {"hit": False, "reason": "candidate message not found in backup"}

    rowid, row_guid, text, date, row_handle = row
    if not text:
        return {
            "hit": False,
            "reason": "candidate found but text is empty in backup",
            "candidate": {
                "rowid": rowid,
                "guid": row_guid,
                "date": date,
                "handle": row_handle,
            },
        }

    encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
    return {
        "hit": True,
        "reason": "found original text in iPhone backup",
        "candidate": {
            "rowid": rowid,
            "guid": row_guid,
            "date": date,
            "handle": row_handle,
        },
        "text_b64": encoded,
        "length": len(text),
    }


def candidate_roots(args: argparse.Namespace) -> list[Path]:
    if args.path:
        return [Path(os.path.expanduser(args.path))]

    sent = apple_ns_to_unix_seconds(args.sent_ns)
    edited = apple_ns_to_unix_seconds(args.edited_ns)
    roots = default_backup_roots(args.home, args.config)
    dated_roots = [
        root
        for root in roots
        if (mtime := manifest_mtime(root)) is not None and sent <= mtime <= edited
    ]
    return sorted(dated_roots, key=lambda root: manifest_mtime(root) or 0, reverse=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handle", required=True)
    parser.add_argument("--guid", required=True)
    parser.add_argument("--sent-ns", type=int, required=True)
    parser.add_argument("--edited-ns", type=int, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--path", default="")
    args = parser.parse_args()

    roots = candidate_roots(args)
    checked: list[dict[str, Any]] = []
    payload: dict[str, Any] = {
        "enabled": True,
        "hit": False,
        "reason": "no matching iPhone backups found",
        "checked": checked,
    }

    for root in roots:
        sms_db, source, resolve_error = resolve_sms_db(root)
        checked_item: dict[str, Any] = {
            "root": str(root),
            "source": source,
            "mtime": manifest_mtime(root),
        }
        if sms_db is not None:
            checked_item["sms_db"] = str(sms_db)

        if resolve_error:
            checked_item["status"] = "skipped"
            checked_item["reason"] = resolve_error
            checked.append(checked_item)
            payload["reason"] = resolve_error
            continue
        if sms_db is None:
            checked_item["status"] = "skipped"
            checked_item["reason"] = "sms.db not found"
            checked.append(checked_item)
            payload["reason"] = "sms.db not found"
            continue

        result = recover_from_sms_db(sms_db, args.guid, args.handle)
        checked_item["status"] = "hit" if result.get("hit") else "miss"
        checked_item["reason"] = result.get("reason")
        checked.append(checked_item)

        payload.update(result)
        payload["backup"] = {
            "root": str(root),
            "source": source,
            "sms_db": str(sms_db),
            "mtime": manifest_mtime(root),
        }
        if result.get("hit"):
            break

    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
