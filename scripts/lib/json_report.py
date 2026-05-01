#!/usr/bin/env python3
"""Build the stable recovery JSON object for recover.sh."""

from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path
from typing import Any


def optional_text(value: str) -> str | None:
    return value if value else None


def read_msi_length(path: Path) -> int | None:
    if not path.exists() or path.stat().st_size == 0:
        return None
    try:
        plist = plistlib.loads(path.read_bytes())
    except Exception:
        return None
    if not isinstance(plist, dict):
        return None
    otr = plist.get("otr")
    if not isinstance(otr, dict):
        return None
    first = otr.get("0") or otr.get(0)
    if not isinstance(first, dict):
        return None
    length = first.get("le")
    return int(length) if isinstance(length, int) else None


def read_wal_candidates(path: Path) -> list[dict[str, Any]]:
    if not path.exists() or path.stat().st_size == 0:
        return []
    try:
        raw = json.loads(path.read_text())
    except Exception:
        return []
    if not isinstance(raw, list):
        return []
    candidates: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        candidates.append(
            {
                "offset": item.get("offset"),
                "length": item.get("length"),
                "text_preview": (item.get("text") or "")[:120],
                "text_b64": item.get("text_b64"),
            }
        )
    return candidates


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ran-at", required=True)
    parser.add_argument("--handle", required=True)
    parser.add_argument("--chat-rowid", default="")
    parser.add_argument("--rowid", default="")
    parser.add_argument("--guid", default="")
    parser.add_argument("--sent-at", default="")
    parser.add_argument("--edited-at", default="")
    parser.add_argument("--msi", type=Path, required=True)
    parser.add_argument("--ab", type=Path, required=True)
    parser.add_argument("--wal-json", type=Path, required=True)
    args = parser.parse_args()

    wal_candidates = read_wal_candidates(args.wal_json)
    recovered = None
    if wal_candidates:
        first = wal_candidates[0]
        recovered = {
            "text_b64": first.get("text_b64"),
            "length": first.get("length"),
            "source": "wal",
            "wal_offset": first.get("offset"),
        }

    ab_size = args.ab.stat().st_size if args.ab.exists() else 0
    msi_size = args.msi.stat().st_size if args.msi.exists() else 0
    payload = {
        "schema_version": 1,
        "ran_at": args.ran_at,
        "handle": args.handle,
        "chat_rowid": int(args.chat_rowid) if args.chat_rowid else None,
        "candidate": {
            "rowid": int(args.rowid) if args.rowid else None,
            "guid": optional_text(args.guid),
            "sent_at": optional_text(args.sent_at),
            "edited_at": optional_text(args.edited_at),
            "msi_otr_le": read_msi_length(args.msi),
        },
        "vectors": {
            "msi": {
                "hit": False,
                "reason": "metadata only" if msi_size else "empty",
            },
            "attributedBody": {
                "hit": False,
                "reason": f"{ab_size} bytes" if ab_size else "0 bytes",
            },
            "wal": {
                "hit": bool(wal_candidates),
                "candidates": wal_candidates,
            },
            "exporter": {
                "hit": False,
                "reason": "not run or no recoverable text",
            },
        },
        "recovered": recovered
        or {
            "text_b64": None,
            "length": None,
            "source": None,
            "wal_offset": None,
        },
    }

    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
