#!/usr/bin/env python3
"""Build the stable recovery JSON object for recover.sh."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from recovery_selection import (
    read_msi_length,
    read_wal_candidates,
    select_preferred_wal_candidate,
    serialize_wal_candidates,
)


def optional_text(value: str) -> str | None:
    return value if value else None


def optional_int(value: str) -> int | None:
    return int(value) if value else None


def read_iphone_backup(path: Path) -> dict[str, Any]:
    if not path.exists() or path.stat().st_size == 0:
        return {"enabled": False, "hit": False, "reason": "not requested"}
    try:
        raw = json.loads(path.read_text())
    except Exception:
        return {"enabled": True, "hit": False, "reason": "could not parse iphone-backup.json"}
    return raw if isinstance(raw, dict) else {"enabled": True, "hit": False, "reason": "invalid iphone-backup.json"}


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
    parser.add_argument("--iphone-json", type=Path, required=True)
    parser.add_argument("--failure-category", default="")
    args = parser.parse_args()

    msi_length = read_msi_length(args.msi)
    raw_wal_candidates = read_wal_candidates(args.wal_json)
    selected_wal = select_preferred_wal_candidate(raw_wal_candidates, msi_length)
    wal_candidates = serialize_wal_candidates(
        raw_wal_candidates,
        msi_length,
        selected_wal.get("selected_candidate_index") if selected_wal else None,
    )
    iphone_backup = read_iphone_backup(args.iphone_json)
    iphone_hit = bool(iphone_backup.get("hit"))
    ab_size = args.ab.stat().st_size if args.ab.exists() else 0
    msi_size = args.msi.stat().st_size if args.msi.exists() else 0

    recovered = {
        "text_b64": selected_wal.get("selected_text_b64") if selected_wal else None,
        "length": selected_wal.get("selected_length") if selected_wal else None,
        "source": "wal" if selected_wal else None,
        "wal_offset": selected_wal.get("offset") if selected_wal else None,
    }
    if selected_wal and selected_wal.get("trimmed_to_msi_length"):
        recovered["trimmed_to_msi_length"] = True
    if not selected_wal and iphone_hit:
        recovered = {
            "text_b64": iphone_backup.get("text_b64"),
            "length": iphone_backup.get("length"),
            "source": "iphone_backup",
            "wal_offset": None,
        }
    if not recovered.get("text_b64"):
        recovered["failure_category"] = args.failure_category or (
            "unknown" if wal_candidates else "wal_checkpointed"
        )

    payload = {
        "schema_version": 1,
        "ran_at": args.ran_at,
        "handle": args.handle,
        "chat_rowid": optional_int(args.chat_rowid),
        "candidate": {
            "rowid": optional_int(args.rowid),
            "guid": optional_text(args.guid),
            "sent_at": optional_text(args.sent_at),
            "edited_at": optional_text(args.edited_at),
            "msi_otr_le": msi_length,
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
            "iphone_backup": {
                "enabled": bool(iphone_backup.get("enabled")),
                "hit": iphone_hit,
                "reason": iphone_backup.get("reason"),
                "backup": iphone_backup.get("backup"),
                "candidate": iphone_backup.get("candidate"),
                "text_b64": iphone_backup.get("text_b64") if iphone_hit else None,
                "length": iphone_backup.get("length") if iphone_hit else None,
                "checked": iphone_backup.get("checked", []),
            },
        },
        "recovered": recovered,
    }

    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
