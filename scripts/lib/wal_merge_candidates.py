#!/usr/bin/env python3
"""Merge GUID-adjacent candidates from a live chat.db-wal and the rolling
wal-history/ buffer (issue #67) into a single JSON array on stdout.

Each candidate is tagged with the source filename so the recovery report can
distinguish "found in the live WAL" from "found in a snapshot taken N seconds
before the retract." Identical text payloads are deduped (first source wins).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from pathlib import Path

# Re-use the existing extractor.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wal_extract import extract_candidates  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--guid", required=True)
    parser.add_argument("--live", type=Path, required=True,
                        help="Path to chat.db-wal copied into the archive")
    parser.add_argument("--history-dir", type=Path, required=True,
                        help="Directory of *.db-wal snapshots (may be empty)")
    args = parser.parse_args()

    sources: list[tuple[Path, str]] = []
    if args.live.is_file():
        sources.append((args.live, "chat.db-wal"))
    if args.history_dir.is_dir():
        for name in sorted(os.listdir(args.history_dir)):
            if name.endswith(".db-wal"):
                sources.append((args.history_dir / name, name))

    seen: set[str] = set()
    merged: list[dict] = []
    for path, label in sources:
        try:
            for offset, text in extract_candidates(path, args.guid):
                key = text[:120]
                if key in seen:
                    continue
                seen.add(key)
                merged.append({
                    "offset": offset,
                    "length": len(text),
                    "text": text,
                    "text_b64": base64.b64encode(text.encode("utf-8")).decode("ascii"),
                    "source": label,
                })
        except OSError:
            continue

    json.dump(merged, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
