#!/usr/bin/env python3
"""Extract GUID-adjacent UTF-8 candidates from an iMessage SQLite WAL."""

from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path


TYPEDSTREAM_MARKER = b"\x04\x0bstreamtyped"


def extract_candidates(wal_path: Path, guid: str) -> list[tuple[int, str]]:
    data = wal_path.read_bytes()
    needle = guid.encode("utf-8")
    hits: list[int] = []
    start = 0
    while True:
        offset = data.find(needle, start)
        if offset < 0:
            break
        hits.append(offset)
        start = offset + 1

    seen: set[str] = set()
    results: list[tuple[int, str]] = []
    for offset in hits:
        after = data[offset + len(needle) : offset + len(needle) + 512]
        end = after.find(TYPEDSTREAM_MARKER)
        if end <= 0:
            continue

        candidate = after[:end]
        while candidate and candidate[0] < 0x20 and candidate[0] not in (0x09, 0x0A, 0x0D):
            candidate = candidate[1:]
        if not candidate:
            continue

        try:
            text = candidate.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if not any(char.isprintable() for char in text):
            continue

        key = text[:120]
        if key in seen:
            continue
        seen.add(key)
        results.append((offset, text))
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("wal_path", type=Path)
    parser.add_argument("guid")
    args = parser.parse_args()

    results = extract_candidates(args.wal_path, args.guid)
    if args.json:
        print(
            json.dumps(
                [
                    {
                        "offset": offset,
                        "length": len(text),
                        "text": text,
                        "text_b64": base64.b64encode(text.encode("utf-8")).decode("ascii"),
                    }
                    for offset, text in results
                ],
                ensure_ascii=False,
            )
        )
        return 0

    for offset, text in results:
        print(f"{offset}\t{len(text)}\t{text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
