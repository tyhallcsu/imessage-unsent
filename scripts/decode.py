#!/usr/bin/env python3
"""
imessage-unsent / decode.py

Decode `attributedBody` (typedstream NSAttributedString) and
`message_summary_info` (binary plist with embedded typedstream blobs in `ec`).

Usage:
    python3 decode.py <attributedBody.bin> <message_summary_info.bin>

Both arguments are paths to BLOB dumps produced by sqlite3 writefile().
For fully retracted messages, both are typically empty — this script reports
that cleanly rather than failing.

Optional dependency: `pip install typedstream`. Without it the script still
parses the bplist and reports its structure; only the typedstream payload
extraction is skipped.
"""
import os
import plistlib
import sys

try:
    import typedstream
    HAVE_TS = True
except ImportError:
    HAVE_TS = False
    print("[warn] python 'typedstream' not installed; install with: pip3 install --user typedstream")


# Names that are framework boilerplate, not message content.
BOILERPLATE = {
    "NSString", "NSAttributedString", "NSDictionary", "NSObject",
    "NSMutableString", "NSMutableAttributedString", "NSArray",
    "NSMutableDictionary", "NSNumber",
    "__kIMMessagePartAttributeName",
    "__kIMBaseWritingDirectionAttributeName",
    "__kIMTextBoldAttributeName",
    "__kIMTextItalicAttributeName",
    "__kIMTextUnderlineAttributeName",
    "__kIMTextStrikethroughAttributeName",
    "__kIMOneTimeCodeAttributeName",
    "__kIMFileTransferGUIDAttributeName",
    "__kIMMentionConfirmedMention",
}


def find_strings(obj, depth=0, seen=None):
    """Walk an arbitrary object graph, yielding non-trivial strings."""
    if seen is None:
        seen = set()
    if depth > 8:
        return
    oid = id(obj)
    if oid in seen:
        return
    seen.add(oid)

    if isinstance(obj, str):
        s = obj.strip()
        if s and len(s) > 1:
            yield s
        return
    if isinstance(obj, bytes):
        try:
            s = obj.decode("utf-8").strip()
            if s and len(s) > 1 and any(c.isprintable() for c in s):
                yield s
        except UnicodeDecodeError:
            pass
        return
    if isinstance(obj, (int, float, bool)) or obj is None:
        return
    if isinstance(obj, dict):
        for v in obj.values():
            yield from find_strings(v, depth + 1, seen)
        return
    if isinstance(obj, (list, tuple, set)):
        for v in obj:
            yield from find_strings(v, depth + 1, seen)
        return
    for attr in ("contents", "value", "string", "string_value", "text", "objects", "values"):
        if hasattr(obj, attr):
            try:
                yield from find_strings(getattr(obj, attr), depth + 1, seen)
            except Exception:
                pass
    if hasattr(obj, "__dict__"):
        for v in vars(obj).values():
            yield from find_strings(v, depth + 1, seen)


def decode_typedstream_blob(data, label):
    if not HAVE_TS:
        print(f"  [{label}] skipped (typedstream module not installed)")
        return
    if not data:
        print(f"  [{label}] empty")
        return
    try:
        obj = typedstream.unarchive_from_data(data)
    except Exception as e:
        print(f"  [{label}] typedstream decode failed: {type(e).__name__}: {e}")
        return
    strings = sorted(set(find_strings(obj)))
    strings = [s for s in strings if s not in BOILERPLATE]
    if not strings:
        print(f"  [{label}] decoded; no non-boilerplate strings found")
        return
    print(f"  [{label}] decoded; {len(strings)} unique non-boilerplate strings:")
    for s in strings:
        print(f"    {s!r}")


def deep_scan_plist(obj, path="root"):
    """Look for any embedded typedstream blob anywhere in the plist tree."""
    SIG = b"streamtyped"
    if isinstance(obj, bytes):
        if SIG in obj:
            print(f"  [deep-scan] typedstream signature at {path} ({len(obj)} bytes)")
            decode_typedstream_blob(obj, f"deep-scan@{path}")
    elif isinstance(obj, dict):
        for k, v in obj.items():
            deep_scan_plist(v, f"{path}.{k}")
    elif isinstance(obj, (list, tuple)):
        for i, v in enumerate(obj):
            deep_scan_plist(v, f"{path}[{i}]")


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip())
        sys.exit(2)
    ab_path, msi_path = sys.argv[1], sys.argv[2]

    print(f"[attributedBody] {ab_path}")
    if os.path.exists(ab_path) and os.path.getsize(ab_path) > 0:
        with open(ab_path, "rb") as f:
            decode_typedstream_blob(f.read(), "attributedBody")
    else:
        print("  empty or missing (expected for fully retracted message)")

    print()
    print(f"[message_summary_info] {msi_path}")
    if not (os.path.exists(msi_path) and os.path.getsize(msi_path) > 0):
        print("  empty or missing")
        return
    with open(msi_path, "rb") as f:
        msi_bytes = f.read()
    try:
        plist = plistlib.loads(msi_bytes)
    except Exception as e:
        print(f"  bplist parse failed: {e}")
        return

    keys = list(plist.keys()) if isinstance(plist, dict) else []
    print(f"  top-level keys: {keys}")
    if "rp" in plist:
        print(f"  rp (retracted parts): {plist['rp']}")
    if "otr" in plist:
        print(f"  otr (original text ranges): {plist['otr']}")
    if "ust" in plist:
        print(f"  ust (user-sent text marker): {plist['ust']}")

    ec = plist.get("ec")
    if not ec:
        print("  ec (edit chronology): ABSENT — full retraction does not preserve text here")
        deep_scan_plist(plist)
        return

    print(f"  ec (edit chronology): present, type={type(ec).__name__}")
    items = ec.items() if isinstance(ec, dict) else enumerate(ec)
    for key, entries in items:
        entries = entries if isinstance(entries, list) else [entries]
        for i, entry in enumerate(entries):
            if not isinstance(entry, dict):
                continue
            blob = entry.get("t") or entry.get("text")
            ts = entry.get("d") or entry.get("date")
            if blob:
                print(f"  ec[{key}][{i}] timestamp={ts}")
                decode_typedstream_blob(blob, f"ec[{key}][{i}]")


if __name__ == "__main__":
    main()
