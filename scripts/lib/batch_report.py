#!/usr/bin/env python3
"""Build the batch-mode JSON array for recover.sh."""

from __future__ import annotations

import argparse
import json
from collections import OrderedDict
from pathlib import Path
from typing import Any


def optional_int(value: str) -> int | None:
    return int(value) if value else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("records", type=Path)
    args = parser.parse_args()

    grouped: OrderedDict[str, dict[str, Any]] = OrderedDict()
    if args.records.exists():
        lines = args.records.read_text().splitlines()
    else:
        lines = []

    for line in lines:
        if not line:
            continue
        fields = line.split("\t")
        fields += [""] * (11 - len(fields))
        (
            handle,
            rowid,
            guid,
            sent_at,
            edited_at,
            date_edited,
            wal_offset,
            wal_length,
            text_b64,
            skipped,
            skip_reason,
        ) = fields[:11]

        item = grouped.setdefault(
            handle,
            {
                "handle": handle,
                "skipped": False,
                "skip_reason": None,
                "candidates": [],
            },
        )

        if skipped == "1":
            item["skipped"] = True
            item["skip_reason"] = skip_reason or "rate_limited"
            continue
        if not rowid:
            continue

        recovered = {
            "source": "wal" if text_b64 else None,
            "text_b64": text_b64 or None,
            "length": optional_int(wal_length),
            "wal_offset": optional_int(wal_offset),
        }
        item["candidates"].append(
            {
                "rowid": optional_int(rowid),
                "guid": guid or None,
                "sent_at": sent_at or None,
                "edited_at": edited_at or None,
                "date_edited": optional_int(date_edited),
                "recovered": recovered,
            }
        )

    print(json.dumps(list(grouped.values()), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
