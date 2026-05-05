#!/usr/bin/env python3
"""Select user-facing recovery text from raw WAL candidates."""

from __future__ import annotations

import argparse
import base64
import json
import plistlib
from pathlib import Path
from typing import Any

PLACEHOLDER_SCALARS = {"\uFFFC", "\uFFFD"}


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
        text = _decode_candidate_text(item)
        text_b64 = item.get("text_b64")
        if text and not isinstance(text_b64, str):
            text_b64 = base64.b64encode(text.encode("utf-8")).decode("ascii")
        length = item.get("length")
        if not isinstance(length, int) and text is not None:
            length = len(text)
        offset = item.get("offset")
        source = item.get("source")
        candidates.append(
            {
                "offset": offset if isinstance(offset, int) else None,
                "length": length if isinstance(length, int) else None,
                "source": source if isinstance(source, str) else None,
                "text": text,
                "text_b64": text_b64 if isinstance(text_b64, str) else None,
            }
        )
    return candidates


def has_visible_non_whitespace_scalar(text: str) -> bool:
    for scalar in text:
        if scalar.isspace() or scalar in PLACEHOLDER_SCALARS:
            continue
        if scalar.isprintable():
            return True
    return False


def normalize_candidate_text(text: str, msi_length: int | None) -> tuple[str, bool]:
    if msi_length is not None and msi_length >= 0 and len(text) > msi_length:
        return text[:msi_length], True
    return text, False


def select_preferred_wal_candidate(
    candidates: list[dict[str, Any]],
    msi_length: int | None,
) -> dict[str, Any] | None:
    best_candidate: dict[str, Any] | None = None
    best_score: tuple[int, int, int, int, int] | None = None

    for index, candidate in enumerate(candidates):
        raw_text = candidate.get("text")
        if not isinstance(raw_text, str):
            continue

        selected_text, trimmed = normalize_candidate_text(raw_text, msi_length)
        if not has_visible_non_whitespace_scalar(selected_text):
            continue

        if msi_length is None:
            delta = 0
            exact_raw = False
            exact_selected = False
        else:
            delta = abs(len(selected_text) - msi_length)
            exact_raw = len(raw_text) == msi_length
            exact_selected = len(selected_text) == msi_length

        score = (
            1 if exact_raw else 0,
            1 if exact_selected else 0,
            -delta,
            1 if not trimmed else 0,
            -index,
        )
        if best_score is not None and score <= best_score:
            continue

        best_candidate = dict(candidate)
        best_candidate.update(
            {
                "selected_candidate_index": index,
                "selected_length": len(selected_text),
                "selected_text": selected_text,
                "selected_text_b64": base64.b64encode(selected_text.encode("utf-8")).decode("ascii"),
                "trimmed_to_msi_length": trimmed,
            }
        )
        best_score = score

    return best_candidate


def serialize_wal_candidates(
    candidates: list[dict[str, Any]],
    msi_length: int | None,
    selected_candidate_index: int | None,
) -> list[dict[str, Any]]:
    serialized: list[dict[str, Any]] = []
    for index, candidate in enumerate(candidates):
        raw_text = candidate.get("text")
        if isinstance(raw_text, str):
            normalized_text, trimmed = normalize_candidate_text(raw_text, msi_length)
            human_readable = has_visible_non_whitespace_scalar(normalized_text)
            preview = raw_text[:120]
        else:
            trimmed = False
            human_readable = False
            preview = ""

        serialized.append(
            {
                "offset": candidate.get("offset"),
                "length": candidate.get("length"),
                "source": candidate.get("source"),
                "text_preview": preview,
                "text_b64": candidate.get("text_b64"),
                "human_readable": human_readable,
                "selected_for_recovery": index == selected_candidate_index,
                "trimmed_to_msi_length": trimmed,
            }
        )
    return serialized


def _decode_candidate_text(item: dict[str, Any]) -> str | None:
    text = item.get("text")
    if isinstance(text, str):
        return text

    text_b64 = item.get("text_b64")
    if not isinstance(text_b64, str) or not text_b64:
        return None

    try:
        raw = base64.b64decode(text_b64)
    except Exception:
        return None

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wal-json", type=Path, required=True)
    parser.add_argument("--msi", type=Path)
    parser.add_argument("--format", choices=("tsv", "json"), default="tsv")
    args = parser.parse_args()

    msi_length = read_msi_length(args.msi) if args.msi else None
    candidates = read_wal_candidates(args.wal_json)
    selected = select_preferred_wal_candidate(candidates, msi_length)

    if args.format == "json":
        payload = serialize_wal_candidates(
            candidates,
            msi_length,
            selected.get("selected_candidate_index") if selected else None,
        )
        print(json.dumps(payload, ensure_ascii=False))
        return 0

    if not selected:
        print("\t\t")
        return 0

    print(
        f"{selected.get('offset', '')}\t{selected['selected_length']}\t{selected['selected_text_b64']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
