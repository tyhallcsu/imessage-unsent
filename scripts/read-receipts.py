#!/usr/bin/env python3
"""Report read/delivery receipt state for iMessages in chat.db.

Messages.app renders a single boolean — "Read" or nothing. chat.db actually
stores two independent facts per direction, and they disagree far more often
than the UI suggests:

    is_read      / date_read
    is_delivered / date_delivered

Which gives three states, not two:

    timestamped    date_* != 0            exact receipt time is on this Mac
    flagged_only   is_* = 1, date_* = 0   Messages shows "Read"/"Delivered",
                                          but the *time* was never written here
    none           is_* = 0, date_* = 0   no receipt at all

`flagged_only` is the state the UI cannot express and the one that generates
the "it says Read — when?" question. It is typical of a row whose status was
synced in by Messages in iCloud from another device: the boolean crosses, the
receipt timestamp does not.

Direction changes what `date_read` *means*:

    is_from_me = 1   the recipient read the message you sent
    is_from_me = 0   you read the message they sent

Read-only by design. Connects via SQLite URI in `mode=ro` and never writes to
chat.db or chat.db-wal. (SQLite does rebuild the `chat.db-shm` WAL index on
attach — see `scripts/lib/chatdb_time.connect_readonly` for why that is both
unavoidable and harmless.) This is Vector 8 in docs/recovery-vectors.md — a
standalone CLI like
Vector 7 (`edit-history.py`), not a step in `recover.sh`, because it operates
on ordinary rows rather than the `is_empty = 1` retraction predicate.

Usage:
    python3 read-receipts.py --rowid 412318
    python3 read-receipts.py --handle '+1XXXXXXXXXX' --since 30d
    python3 read-receipts.py --audit --since 90d --json

Message text is never printed unless you pass `--with-text`, so the default
output is safe to paste into an issue.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from chatdb_time import (  # noqa: E402
    apple_ns_to_iso,
    apple_ns_to_unix_ns,
    connect_readonly,
    normalize_apple_ts,
    parse_since,
    since_ns_to_apple_cutoff,
)

SCHEMA_VERSION = 1

STATE_TIMESTAMPED = "timestamped"
STATE_FLAGGED_ONLY = "flagged_only"
STATE_NONE = "none"

# Whether the transport can carry a read receipt at all. Feeding SMS rows into
# the receipt inference would poison it — SMS has no read-receipt concept, so
# every SMS row looks like "receipts are off".
SERVICE_RECEIPT_SUPPORT = {
    "iMessage": "supported",
    "RCS": "carrier-dependent",
    "SMS": "unsupported",
}

# Consecutive most-recent outgoing iMessages without a read *timestamp* before
# the tool will call the pattern a trend rather than noise.
DEFAULT_MIN_RUN = 10

# Share of a run that one explanation must hold before it becomes the headline
# rather than "mixed". The minority is still reported in the note either way.
DOMINANCE_SHARE = 0.9


@dataclass
class ReceiptRecord:
    """Receipt state for one `message` row."""
    rowid: int
    guid: str
    handle: str | None
    handle_source: str  # "handle" | "chat" | "unknown"
    service: str | None
    is_from_me: bool
    is_group_chat: bool
    is_retracted: bool
    sent_at_ns: int  # ns since UNIX epoch
    sent_at_iso: str
    delivered_state: str
    delivered_at_ns: int
    delivered_at_iso: str
    read_state: str
    read_at_ns: int
    read_at_iso: str
    read_latency_seconds: float | None
    text: str | None = None

    @property
    def direction(self) -> str:
        return "outgoing" if self.is_from_me else "incoming"

    @property
    def read_meaning(self) -> str:
        if self.is_from_me:
            return "the recipient read the message you sent"
        return "you read the message they sent"

    @property
    def receipt_support(self) -> str:
        return SERVICE_RECEIPT_SUPPORT.get(self.service or "", "unknown")


@dataclass
class ThreadSummary:
    """Aggregate receipt health for one handle."""
    handle: str | None
    messages: int
    outgoing: int
    incoming: int
    group_messages: int = 0
    outgoing_read: dict[str, int] = field(default_factory=dict)
    outgoing_delivered: dict[str, int] = field(default_factory=dict)
    incoming_read: dict[str, int] = field(default_factory=dict)
    latency: dict[str, float | int | None] = field(default_factory=dict)
    last_timestamped_read_iso: str = ""
    inference: dict[str, object] = field(default_factory=dict)


def classify_state(flag: int | None, ts_ns: int) -> str:
    """Three-state receipt classification. A timestamp always wins the flag."""
    if ts_ns:
        return STATE_TIMESTAMPED
    if flag:
        return STATE_FLAGGED_ONLY
    return STATE_NONE


def _percentile(values: list[float], pct: float) -> float | None:
    """Linear-interpolated percentile over a pre-sorted list."""
    if not values:
        return None
    k = (len(values) - 1) * pct
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return values[int(k)]
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def fetch_receipts(
    db_path: Path,
    handle: str | None = None,
    rowid: int | None = None,
    guid: str | None = None,
    since_ns: int | None = None,
    direction: str = "any",
    service: str | None = None,
    limit: int = 200,
    with_text: bool = False,
) -> list[ReceiptRecord]:
    conn = connect_readonly(db_path)
    try:
        clauses: list[str] = []
        params: list[object] = []
        if rowid is not None:
            clauses.append("m.ROWID = ?")
            params.append(rowid)
        if guid is not None:
            clauses.append("m.guid = ?")
            params.append(guid)
        if handle is not None:
            # `message.handle_id` is 0 on roughly half of all *outgoing* rows —
            # Messages only populates it consistently for inbound. Matching on
            # `handle.id` alone would silently drop most of what this tool is
            # for, so fall back to the message's chat membership, which also
            # makes `--handle` work for that person's group chats.
            clauses.append("""(
                h.id = ?
                OR EXISTS (
                    SELECT 1 FROM chat_message_join cmj
                      JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
                      JOIN handle hh ON hh.ROWID = chj.handle_id
                     WHERE cmj.message_id = m.ROWID AND hh.id = ?
                )
            )""")
            params.extend([handle, handle])
        if direction == "outgoing":
            clauses.append("m.is_from_me = 1")
        elif direction == "incoming":
            clauses.append("m.is_from_me = 0")
        if service:
            clauses.append("m.service = ?")
            params.append(service)
        if since_ns is not None:
            clauses.append("m.date >= ?")
            params.append(since_ns_to_apple_cutoff(since_ns))
        where = " AND ".join(clauses) if clauses else "1 = 1"

        # A correlated subquery rather than a join through chat_message_join:
        # a message can belong to more than one chat, and a join would emit
        # duplicate rows for it.
        participants = """
            (SELECT COUNT(*) FROM chat_handle_join chj
              WHERE chj.chat_id = (SELECT cmj.chat_id FROM chat_message_join cmj
                                    WHERE cmj.message_id = m.ROWID LIMIT 1))
        """
        chat_identifier = """
            (SELECT c.chat_identifier FROM chat c
               JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
              WHERE cmj.message_id = m.ROWID LIMIT 1)
        """
        text_col = "m.text" if with_text else "NULL"
        sql = f"""
            SELECT m.ROWID, m.guid, h.id AS handle,
                   {chat_identifier} AS chat_identifier, m.service,
                   m.date, m.date_read, m.is_read,
                   m.date_delivered, m.is_delivered,
                   m.is_from_me, m.is_empty, m.date_edited,
                   {participants} AS participants,
                   {text_col} AS body
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE {where}
            ORDER BY m.date DESC
            LIMIT ?
        """
        params.append(limit)
        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as exc:
            raise SystemExit(
                f"query failed against {db_path}: {exc}\n"
                "(this tool expects a Messages chat.db schema with is_read/date_read)"
            ) from exc
    finally:
        conn.close()

    out: list[ReceiptRecord] = []
    for (
        rowid_, guid_, handle_, chat_identifier_, service_,
        date_ns, read_ns, is_read,
        delivered_ns, is_delivered, is_from_me, is_empty, date_edited,
        participants_, body,
    ) in rows:
        if handle_:
            resolved_handle, handle_source = handle_, "handle"
        elif chat_identifier_:
            resolved_handle, handle_source = chat_identifier_, "chat"
        else:
            resolved_handle, handle_source = None, "unknown"

        sent_apple = normalize_apple_ts(date_ns)
        read_apple = normalize_apple_ts(read_ns)
        delivered_apple = normalize_apple_ts(delivered_ns)

        latency: float | None = None
        if sent_apple and read_apple:
            latency = (read_apple - sent_apple) / 1_000_000_000

        out.append(
            ReceiptRecord(
                rowid=rowid_,
                guid=guid_,
                handle=resolved_handle,
                handle_source=handle_source,
                service=service_,
                is_from_me=bool(is_from_me),
                is_group_chat=bool(participants_ and participants_ > 1),
                # The Sequoia retraction predicate — see README. `date_edited`
                # is non-zero for edits *and* retractions; `is_empty` splits them.
                is_retracted=bool(date_edited) and bool(is_empty),
                sent_at_ns=apple_ns_to_unix_ns(date_ns),
                sent_at_iso=apple_ns_to_iso(date_ns),
                delivered_state=classify_state(is_delivered, delivered_apple),
                delivered_at_ns=apple_ns_to_unix_ns(delivered_ns),
                delivered_at_iso=apple_ns_to_iso(delivered_ns),
                read_state=classify_state(is_read, read_apple),
                read_at_ns=apple_ns_to_unix_ns(read_ns),
                read_at_iso=apple_ns_to_iso(read_ns),
                read_latency_seconds=latency,
                text=body if with_text else None,
            )
        )
    return out


def _census(records: list[ReceiptRecord], attr: str) -> dict[str, int]:
    counts = {STATE_TIMESTAMPED: 0, STATE_FLAGGED_ONLY: 0, STATE_NONE: 0}
    for r in records:
        counts[getattr(r, attr)] += 1
    return counts


def infer_receipt_trend(
    records: list[ReceiptRecord], min_run: int = DEFAULT_MIN_RUN
) -> dict[str, object]:
    """Classify why recent outgoing messages lack read *timestamps*.

    This is an inference from an absence, not proof of anything the other
    party did. It looks only at outgoing 1:1 iMessage rows:

    - SMS carries no read receipt at all, so including it would manufacture a
      false "receipts off" signal.
    - Group rows carry a single `date_read` for the whole chat rather than one
      per participant, so they cannot speak to whether *this* person read
      anything.
    """
    outgoing = sorted(
        (
            r for r in records
            if r.is_from_me and r.service == "iMessage" and not r.is_group_chat
        ),
        key=lambda r: r.sent_at_ns,
        reverse=True,
    )
    base: dict[str, object] = {
        "status": "no_data",
        "threshold": min_run,
        "run_length": 0,
        "run_flagged_only": 0,
        "run_none": 0,
        "boundary_iso": "",
        "note": "no outgoing iMessages in this window",
    }
    if not outgoing:
        return base

    run = 0
    for r in outgoing:
        if r.read_state == STATE_TIMESTAMPED:
            break
        run += 1
    run_records = outgoing[:run]
    run_flagged = sum(1 for r in run_records if r.read_state == STATE_FLAGGED_ONLY)
    run_none = run - run_flagged
    has_timestamped = run < len(outgoing)

    base.update({
        "run_length": run,
        "run_flagged_only": run_flagged,
        "run_none": run_none,
        "boundary_iso": run_records[-1].sent_at_iso if run_records else "",
    })

    if run == 0:
        base.update({
            "status": "observed",
            "note": "the most recent outgoing iMessage has a read timestamp",
        })
    elif run < min_run:
        base.update({
            "status": "unclear",
            "note": (
                f"only {run} recent outgoing iMessage(s) lack a read timestamp — below "
                f"the {min_run} threshold, so no trend is claimed."
            ),
        })
    else:
        # Composition of the run decides the headline. The note always carries
        # both counts so a lopsided-but-not-unanimous run can't read as
        # unanimous.
        breakdown = (
            f"the last {run} outgoing 1:1 iMessage(s) have no read timestamp: "
            f"{run_flagged} flagged read (read — the time was not recorded here) and "
            f"{run_none} with no flag at all (unread, or receipts off)."
        )
        if run_none / run >= DOMINANCE_SHARE:
            base.update({
                "status": "likely_disabled",
                "note": (
                    f"{breakdown} Consistent with read receipts being off on the other "
                    "side. Inference from an absence, not proof — a thread nobody "
                    "opened looks identical."
                ),
            })
        elif run_flagged / run >= DOMINANCE_SHARE:
            base.update({
                "status": "flags_without_timestamps",
                "note": (
                    f"{breakdown} They were read; this Mac just never recorded when. "
                    "Typical of Messages in iCloud syncing the flag in from another "
                    "device, which carries the boolean but not the receipt time."
                ),
            })
        else:
            base.update({
                "status": "mixed",
                "note": f"{breakdown} No single explanation is claimed.",
            })

    if not has_timestamped and run > 0:
        base["status"] = "never_observed_in_window"
        base["note"] = (
            f"no outgoing iMessage in this window has a read timestamp ({run} checked). "
            "Widen --since before drawing any conclusion."
        )
    return base


def summarize_thread(
    handle: str | None, records: list[ReceiptRecord], min_run: int = DEFAULT_MIN_RUN
) -> ThreadSummary:
    outgoing = [r for r in records if r.is_from_me]
    incoming = [r for r in records if not r.is_from_me]

    # Latency answers "how long until *they* read it", which a group row can't
    # support — its single date_read says only that someone did.
    latencies = sorted(
        r.read_latency_seconds
        for r in outgoing
        if r.read_latency_seconds is not None
        and r.read_latency_seconds >= 0
        and not r.is_group_chat
    )
    latency = {
        "count": len(latencies),
        "p50_seconds": _percentile(latencies, 0.50),
        "p90_seconds": _percentile(latencies, 0.90),
        "min_seconds": latencies[0] if latencies else None,
        "max_seconds": latencies[-1] if latencies else None,
    }

    timestamped = [r for r in outgoing if r.read_state == STATE_TIMESTAMPED]
    last_read = max(timestamped, key=lambda r: r.read_at_ns).read_at_iso if timestamped else ""

    return ThreadSummary(
        handle=handle,
        messages=len(records),
        outgoing=len(outgoing),
        incoming=len(incoming),
        group_messages=sum(1 for r in records if r.is_group_chat),
        outgoing_read=_census(outgoing, "read_state"),
        outgoing_delivered=_census(outgoing, "delivered_state"),
        incoming_read=_census(incoming, "read_state"),
        latency=latency,
        last_timestamped_read_iso=last_read,
        inference=infer_receipt_trend(records, min_run=min_run),
    )


def summarize_by_handle(
    records: list[ReceiptRecord], min_run: int = DEFAULT_MIN_RUN
) -> list[ThreadSummary]:
    buckets: dict[str | None, list[ReceiptRecord]] = {}
    for r in records:
        buckets.setdefault(r.handle, []).append(r)
    summaries = [summarize_thread(h, rs, min_run=min_run) for h, rs in buckets.items()]
    summaries.sort(key=lambda s: s.messages, reverse=True)
    return summaries


def _state_display(state: str, iso: str) -> str:
    if state == STATE_TIMESTAMPED:
        return iso or "(timestamp present but unparseable)"
    if state == STATE_FLAGGED_ONLY:
        return "flagged, no timestamp recorded"
    return "—"


def _fmt_duration(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    seconds = float(seconds)
    if seconds < 60:
        return f"{seconds:.1f}s"
    if seconds < 3600:
        return f"{seconds / 60:.1f}m"
    if seconds < 86_400:
        return f"{seconds / 3600:.1f}h"
    return f"{seconds / 86_400:.1f}d"


def render_detail(r: ReceiptRecord) -> str:
    lines = [
        "=" * 72,
        f"ROWID {r.rowid}  GUID {r.guid}",
        f"  handle    : {r.handle or '(none)'}"
        + ("  (resolved from the chat — message.handle_id is unset)"
           if r.handle_source == "chat" else ""),
        f"  service   : {r.service or '(none)'} (read receipts: {r.receipt_support})",
        f"  direction : {r.direction} — date_read means {r.read_meaning}",
        f"  chat      : {'group' if r.is_group_chat else '1:1'}",
        f"  sent      : {r.sent_at_iso}",
        f"  delivered : {_state_display(r.delivered_state, r.delivered_at_iso)}"
        f"  [{r.delivered_state}]",
        f"  read      : {_state_display(r.read_state, r.read_at_iso)}"
        f"  [{r.read_state}]",
        f"  latency   : {_fmt_duration(r.read_latency_seconds)}",
    ]
    if r.is_retracted:
        lines.append("  retracted : yes — the sender unsent this message")
    if r.is_group_chat:
        lines.append(
            "  note      : group chat — chat.db stores one date_read per message, "
            "not one per participant"
        )
    if r.read_state == STATE_FLAGGED_ONLY:
        lines.append(
            "  note      : Messages shows this as read, but the receipt time was "
            "never written to this Mac. Only a device that received the receipt "
            "directly can still have it."
        )
    if r.text is not None:
        lines.append(f"  text      : {r.text!r}")
    return "\n".join(lines)


def render_table(records: list[ReceiptRecord]) -> str:
    header = (
        f"{'ROWID':>8}  {'dir':<3}  {'service':<8}  {'sent':<26}  "
        f"{'delivered':<30}  {'read':<30}  {'latency':>8}"
    )
    lines = [header, "-" * len(header)]
    for r in records:
        lines.append(
            f"{r.rowid:>8}  {'out' if r.is_from_me else 'in':<3}  "
            f"{(r.service or '?'):<8}  {r.sent_at_iso:<26}  "
            f"{_state_display(r.delivered_state, r.delivered_at_iso):<30}  "
            f"{_state_display(r.read_state, r.read_at_iso):<30}  "
            f"{_fmt_duration(r.read_latency_seconds):>8}"
        )
        if r.text is not None:
            lines.append(f"{'':>8}  text: {r.text!r}")
    return "\n".join(lines)


def render_summary(summary: ThreadSummary) -> str:
    lat = summary.latency
    lines = [
        "=" * 72,
        f"handle {summary.handle or '(none)'} — {summary.messages} message(s) in window",
        f"  outgoing  : {summary.outgoing}   incoming: {summary.incoming}"
        + (f"   ({summary.group_messages} in group chats — excluded from "
           "latency and trend, no per-participant read state)"
           if summary.group_messages else ""),
        "  outgoing read state    : "
        f"timestamped={summary.outgoing_read.get(STATE_TIMESTAMPED, 0)} "
        f"flagged_only={summary.outgoing_read.get(STATE_FLAGGED_ONLY, 0)} "
        f"none={summary.outgoing_read.get(STATE_NONE, 0)}",
        "  outgoing delivery state: "
        f"timestamped={summary.outgoing_delivered.get(STATE_TIMESTAMPED, 0)} "
        f"flagged_only={summary.outgoing_delivered.get(STATE_FLAGGED_ONLY, 0)} "
        f"none={summary.outgoing_delivered.get(STATE_NONE, 0)}",
        "  incoming read state    : "
        f"timestamped={summary.incoming_read.get(STATE_TIMESTAMPED, 0)} "
        f"flagged_only={summary.incoming_read.get(STATE_FLAGGED_ONLY, 0)} "
        f"none={summary.incoming_read.get(STATE_NONE, 0)}",
        f"  send→read latency      : n={lat.get('count', 0)} "
        f"p50={_fmt_duration(lat.get('p50_seconds'))} "
        f"p90={_fmt_duration(lat.get('p90_seconds'))} "
        f"max={_fmt_duration(lat.get('max_seconds'))}",
        f"  last read timestamp    : {summary.last_timestamped_read_iso or '(none in window)'}",
        f"  receipt trend          : {summary.inference.get('status')}",
        f"    {summary.inference.get('note')}",
    ]
    return "\n".join(lines)


def render_text(
    records: list[ReceiptRecord], summaries: list[ThreadSummary], detail: bool
) -> str:
    if not records:
        return "No messages matched.\n"
    chunks: list[str] = []
    if detail:
        chunks.extend(render_detail(r) for r in records)
    else:
        chunks.append(render_table(records))
    chunks.extend(render_summary(s) for s in summaries)
    return "\n".join(chunks) + "\n"


def _record_json(r: ReceiptRecord) -> dict[str, object]:
    payload: dict[str, object] = {
        "rowid": r.rowid,
        "guid": r.guid,
        "handle": r.handle,
        "handle_source": r.handle_source,
        "service": r.service,
        "receipt_support": r.receipt_support,
        "direction": r.direction,
        "read_meaning": r.read_meaning,
        "is_group_chat": r.is_group_chat,
        "is_retracted": r.is_retracted,
        "sent_at_ns": r.sent_at_ns,
        "sent_at_iso": r.sent_at_iso,
        "delivered_state": r.delivered_state,
        "delivered_at_ns": r.delivered_at_ns,
        "delivered_at_iso": r.delivered_at_iso,
        "read_state": r.read_state,
        "read_at_ns": r.read_at_ns,
        "read_at_iso": r.read_at_iso,
        "read_latency_seconds": r.read_latency_seconds,
    }
    if r.text is not None:
        payload["text"] = r.text
    return payload


def render_json(
    records: list[ReceiptRecord],
    summaries: list[ThreadSummary],
    query: dict[str, object],
    truncated: bool,
) -> str:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "query": query,
        "truncated": truncated,
        "messages": [_record_json(r) for r in records],
        "threads": [
            {
                "handle": s.handle,
                "messages": s.messages,
                "outgoing": s.outgoing,
                "incoming": s.incoming,
                "group_messages": s.group_messages,
                "outgoing_read": s.outgoing_read,
                "outgoing_delivered": s.outgoing_delivered,
                "incoming_read": s.incoming_read,
                "latency": s.latency,
                "last_timestamped_read_iso": s.last_timestamped_read_iso,
                "inference": s.inference,
            }
            for s in summaries
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Report read/delivery receipt state for iMessages in chat.db.",
        epilog="See docs/recovery-vectors.md (Vector 8) for the state model.",
    )
    parser.add_argument(
        "--db",
        default=os.path.expanduser("~/Library/Messages/chat.db"),
        help="path to chat.db (default: ~/Library/Messages/chat.db, opened read-only)",
    )
    parser.add_argument("--handle", help="filter by E.164 phone or Apple ID email")
    parser.add_argument("--rowid", type=int, help="filter by message.ROWID")
    parser.add_argument("--guid", help="filter by message.guid")
    parser.add_argument(
        "--since",
        default="30d",
        help="recency window (e.g. 24h, 7d, 30d, or 'all'); default: 30d",
    )
    parser.add_argument(
        "--direction",
        choices=("any", "outgoing", "incoming"),
        default="any",
        help="restrict by direction (default: any)",
    )
    parser.add_argument(
        "--service",
        help="restrict by transport (iMessage, SMS, RCS). SMS carries no read receipts.",
    )
    parser.add_argument(
        "--limit", type=int, default=200, help="max rows to inspect (default: 200)"
    )
    parser.add_argument(
        "--audit",
        action="store_true",
        help="per-handle receipt-health summary instead of a message list",
    )
    parser.add_argument(
        "--min-run",
        type=int,
        default=DEFAULT_MIN_RUN,
        help=f"consecutive un-timestamped outgoing messages before the trend "
             f"inference fires (default: {DEFAULT_MIN_RUN})",
    )
    parser.add_argument(
        "--with-text",
        action="store_true",
        help="include message text in the output (off by default — output is "
             "safe to share without it)",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = parser.parse_args(argv)

    since_ns = parse_since(args.since)
    records = fetch_receipts(
        db_path=Path(args.db),
        handle=args.handle,
        rowid=args.rowid,
        guid=args.guid,
        since_ns=since_ns,
        direction=args.direction,
        service=args.service,
        limit=args.limit,
        with_text=args.with_text,
    )
    truncated = len(records) == args.limit

    single = args.rowid is not None or args.guid is not None
    if args.audit:
        summaries = summarize_by_handle(records, min_run=args.min_run)
    elif args.handle is not None and records:
        summaries = [summarize_thread(args.handle, records, min_run=args.min_run)]
    else:
        summaries = []

    query = {
        "db": str(args.db),
        "handle": args.handle,
        "rowid": args.rowid,
        "guid": args.guid,
        "since": args.since,
        "direction": args.direction,
        "service": args.service,
        "limit": args.limit,
        "min_run": args.min_run,
    }

    if args.json:
        sys.stdout.write(render_json(records, summaries, query, truncated) + "\n")
    else:
        sys.stdout.write(render_text(records, summaries, detail=single))
        if truncated:
            sys.stdout.write(
                f"\nnote: hit --limit {args.limit}; older messages in this window were "
                "not inspected, so the summary and trend above are partial.\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
