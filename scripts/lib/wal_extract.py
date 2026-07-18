#!/usr/bin/env python3
"""Extract GUID-adjacent UTF-8 candidates from an iMessage SQLite WAL."""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path


TYPEDSTREAM_MARKER = b"\x04\x0bstreamtyped"

# Bytes after a GUID hit to scan for the next-column `streamtyped` marker that
# terminates the inline `text` value. The original 512-byte window silently
# dropped any message whose terminator landed further out — i.e. exactly the
# long messages the tool most wants to recover (F-H4 / #110). 8 KB comfortably
# covers any message stored inline in a SQLite leaf cell while staying bounded
# and fast; the downstream `otr.0.le` cross-check in recovery_selection.py trims
# any over-capture back to the true length, so a generous window is safe.
DEFAULT_WINDOW = 8192

# Minimum fraction of a full window that must decode to printable text before we
# treat a marker-less hit as a *truncated long message* worth reporting (rather
# than an incidental GUID hit in an index/join with only binary bytes after it).
_TRUNCATION_PRINTABLE_RATIO = 0.8


def extract_candidates(
    wal_path: Path,
    guid: str,
    window: int = DEFAULT_WINDOW,
    warn: bool = True,
) -> list[tuple[int, str]]:
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
    truncated_hits = 0
    for offset in hits:
        after = data[offset + len(needle) : offset + len(needle) + window]
        end = after.find(TYPEDSTREAM_MARKER)
        if end < 0:
            # No next-column marker within the window. Distinguish a real
            # long-message truncation (the window is full and looks like text)
            # from an incidental non-text GUID hit, so the drop is reported
            # rather than silent.
            if len(after) >= window and _looks_like_text(after):
                truncated_hits += 1
            continue
        if end == 0:
            # Marker sits immediately after the GUID: no inline text to recover.
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

    if warn and truncated_hits:
        print(
            f"wal_extract: {truncated_hits} GUID hit(s) had text extending past "
            f"the {window}-byte scan window; a longer message may be truncated. "
            f"Re-run with --window to widen the scan.",
            file=sys.stderr,
        )
    return results


def _looks_like_text(chunk: bytes) -> bool:
    """Heuristic: does a full window decode to mostly-printable UTF-8?

    Used only to decide whether a marker-less GUID hit is a truncated long
    message (report it) versus incidental binary (ignore it). Deliberately
    lenient on encoding — a boundary that splits a multi-byte sequence must not
    flip the verdict.
    """
    if not chunk:
        return False
    probe = chunk.decode("utf-8", errors="ignore")
    if not probe:
        return False
    printable = sum(1 for ch in probe if ch.isprintable() or ch in "\t\n\r")
    return printable >= len(probe) * _TRUNCATION_PRINTABLE_RATIO


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--window",
        type=int,
        default=DEFAULT_WINDOW,
        help=f"bytes after each GUID hit to scan for the text terminator (default {DEFAULT_WINDOW})",
    )
    parser.add_argument("wal_path", type=Path)
    parser.add_argument("guid")
    args = parser.parse_args()

    if args.window <= 0:
        parser.error("--window must be a positive integer")

    results = extract_candidates(args.wal_path, args.guid, window=args.window)
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
