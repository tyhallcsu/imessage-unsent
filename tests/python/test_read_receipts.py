"""Tests for `scripts/read-receipts.py` (Vector 8) against the synthetic fixture.

The fixture builder seeds five rows at ROWID 400-404 covering every receipt
state the classifier has to tell apart:

    400  outgoing iMessage  read with timestamp        (timestamped)
    401  outgoing iMessage  read flag, no timestamp    (flagged_only)
    402  outgoing iMessage  delivered, never read      (none)
    403  outgoing SMS       no receipts at all         (none, unsupported)
    404  incoming iMessage  read by me with timestamp  (timestamped)

Rows 100-102 / 200 / 300 predate this vector and carry no read state, which
makes them useful as the "quiet" background in the thread summary.
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path


def _load_module(repo_root: Path):
    script = repo_root / "scripts" / "read-receipts.py"
    spec = importlib.util.spec_from_file_location("imu_read_receipts", script)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["imu_read_receipts"] = module
    spec.loader.exec_module(module)
    return module


def _by_rowid(records):
    return {r.rowid: r for r in records}


def _fetch_all(module, fixture_messages, **kwargs):
    return module.fetch_receipts(
        db_path=fixture_messages / "chat.db", since_ns=None, **kwargs
    )


def test_three_state_classification(repo_root, fixture_messages):
    module = _load_module(repo_root)
    rows = _by_rowid(_fetch_all(module, fixture_messages))

    assert rows[400].read_state == "timestamped"
    assert rows[400].read_at_iso != ""
    assert rows[401].read_state == "flagged_only"
    assert rows[401].read_at_iso == ""
    assert rows[401].read_at_ns == 0
    assert rows[402].read_state == "none"
    assert rows[403].read_state == "none"
    assert rows[404].read_state == "timestamped"


def test_delivery_state_is_independent_of_read_state(repo_root, fixture_messages):
    module = _load_module(repo_root)
    rows = _by_rowid(_fetch_all(module, fixture_messages))

    # Delivered with a timestamp but never read.
    assert rows[402].delivered_state == "timestamped"
    assert rows[402].read_state == "none"
    # Flagged delivered *and* flagged read, neither timestamped.
    assert rows[401].delivered_state == "flagged_only"
    # SMS: no delivery receipt either.
    assert rows[403].delivered_state == "none"


def test_classify_state_prefers_timestamp_over_flag(repo_root):
    module = _load_module(repo_root)
    assert module.classify_state(0, 12345) == "timestamped"
    assert module.classify_state(1, 12345) == "timestamped"
    assert module.classify_state(1, 0) == "flagged_only"
    assert module.classify_state(0, 0) == "none"
    assert module.classify_state(None, 0) == "none"


def test_direction_semantics_and_service_support(repo_root, fixture_messages):
    module = _load_module(repo_root)
    rows = _by_rowid(_fetch_all(module, fixture_messages))

    assert rows[400].direction == "outgoing"
    assert rows[400].read_meaning == "the recipient read the message you sent"
    assert rows[404].direction == "incoming"
    assert rows[404].read_meaning == "you read the message they sent"

    assert rows[400].receipt_support == "supported"
    assert rows[403].receipt_support == "unsupported"


def test_latency_only_when_both_ends_timestamped(repo_root, fixture_messages):
    module = _load_module(repo_root)
    rows = _by_rowid(_fetch_all(module, fixture_messages))

    assert rows[400].read_latency_seconds == 65.0
    assert rows[404].read_latency_seconds == 12.0
    assert rows[401].read_latency_seconds is None
    assert rows[402].read_latency_seconds is None


def test_retraction_and_group_flags(repo_root, fixture_messages):
    module = _load_module(repo_root)
    rows = _by_rowid(_fetch_all(module, fixture_messages))

    # ROWID 200 is the fixture's retracted message (date_edited != 0, is_empty = 1).
    assert rows[200].is_retracted is True
    # ROWID 300 is *edited*, not retracted — is_empty stays 0.
    assert rows[300].is_retracted is False
    # The fixture chat has a single participant, so nothing is a group chat.
    assert all(not r.is_group_chat for r in rows.values())


def test_filters(repo_root, fixture_messages):
    module = _load_module(repo_root)

    only_400 = _fetch_all(module, fixture_messages, rowid=400)
    assert [r.rowid for r in only_400] == [400]

    by_guid = _fetch_all(
        module, fixture_messages, guid="00000000-0000-0000-0000-000000000401"
    )
    assert [r.rowid for r in by_guid] == [401]

    outgoing = _fetch_all(module, fixture_messages, direction="outgoing")
    assert {r.rowid for r in outgoing} == {400, 401, 402, 403}

    sms = _fetch_all(module, fixture_messages, service="SMS")
    assert [r.rowid for r in sms] == [403]

    none = _fetch_all(module, fixture_messages, handle="+19999999999")
    assert none == []


def test_thread_summary_census(repo_root, fixture_messages):
    module = _load_module(repo_root)
    records = _fetch_all(module, fixture_messages, handle="+15551234567")
    summary = module.summarize_thread("+15551234567", records)

    assert summary.outgoing == 4
    assert summary.outgoing_read == {"timestamped": 1, "flagged_only": 1, "none": 2}
    assert summary.outgoing_delivered["timestamped"] == 2
    assert summary.latency["count"] == 1
    assert summary.latency["p50_seconds"] == 65.0
    assert summary.last_timestamped_read_iso != ""


def test_inference_excludes_sms(repo_root, fixture_messages):
    """SMS carries no read receipt, so it must not feed the trend inference."""
    module = _load_module(repo_root)
    records = _fetch_all(module, fixture_messages)

    inference = module.infer_receipt_trend(records, min_run=2)
    # Newest-first outgoing iMessages are 402 (none) and 401 (flagged_only);
    # the SMS row 403 is newer than both and is skipped entirely.
    assert inference["run_length"] == 2
    assert inference["run_none"] == 1
    assert inference["run_flagged_only"] == 1
    assert inference["status"] == "mixed"


def test_inference_respects_min_run_threshold(repo_root, fixture_messages):
    module = _load_module(repo_root)
    records = _fetch_all(module, fixture_messages)

    inference = module.infer_receipt_trend(records, min_run=5)
    assert inference["status"] == "unclear"
    assert inference["threshold"] == 5


def test_inference_has_no_data_without_outgoing(repo_root, fixture_messages):
    module = _load_module(repo_root)
    incoming = _fetch_all(module, fixture_messages, direction="incoming")
    assert module.infer_receipt_trend(incoming)["status"] == "no_data"


def test_percentile_interpolates(repo_root):
    module = _load_module(repo_root)
    assert module._percentile([], 0.5) is None
    assert module._percentile([1.0], 0.5) == 1.0
    assert module._percentile([0.0, 10.0], 0.5) == 5.0
    assert module._percentile([0.0, 1.0, 2.0, 3.0], 0.9) == 2.7


def test_text_is_withheld_by_default(repo_root, fixture_messages):
    """Default output must be safe to share: no message bodies."""
    module = _load_module(repo_root)
    quiet = _by_rowid(_fetch_all(module, fixture_messages, rowid=400))
    assert quiet[400].text is None

    loud = _by_rowid(_fetch_all(module, fixture_messages, rowid=400, with_text=True))
    assert loud[400].text == "receipt fixture: outgoing, read with timestamp"


def _run_cli(repo_root, db, *args):
    return subprocess.run(
        [sys.executable, str(repo_root / "scripts" / "read-receipts.py"),
         "--db", str(db), "--since", "all", *args],
        check=True,
        capture_output=True,
        text=True,
    )


def test_json_cli_path(repo_root, fixture_messages):
    result = _run_cli(
        repo_root, fixture_messages / "chat.db", "--handle", "+15551234567", "--json"
    )
    payload = json.loads(result.stdout)

    assert payload["schema_version"] == 1
    assert payload["truncated"] is False
    assert payload["query"]["handle"] == "+15551234567"

    by_rowid = {m["rowid"]: m for m in payload["messages"]}
    assert by_rowid[401]["read_state"] == "flagged_only"
    assert by_rowid[401]["read_at_iso"] == ""
    assert by_rowid[400]["read_latency_seconds"] == 65.0
    assert "text" not in by_rowid[400]

    assert len(payload["threads"]) == 1
    assert payload["threads"][0]["handle"] == "+15551234567"


def test_json_truncation_is_reported(repo_root, fixture_messages):
    """A --limit that clips the result set must say so, not silently truncate."""
    result = _run_cli(repo_root, fixture_messages / "chat.db", "--limit", "2", "--json")
    payload = json.loads(result.stdout)
    assert payload["truncated"] is True
    assert len(payload["messages"]) == 2


def test_text_cli_detail_mode(repo_root, fixture_messages):
    result = _run_cli(repo_root, fixture_messages / "chat.db", "--rowid", "401")
    assert "flagged, no timestamp recorded" in result.stdout
    assert "the recipient read the message you sent" in result.stdout
    # The body must not appear unless asked for.
    assert "receipt fixture" not in result.stdout

    with_text = _run_cli(
        repo_root, fixture_messages / "chat.db", "--rowid", "401", "--with-text"
    )
    assert "receipt fixture" in with_text.stdout


def test_readonly_invariant(repo_root, fixture_messages):
    """The tool must not mutate chat.db. Compare bytes before/after."""
    db = fixture_messages / "chat.db"
    before = db.read_bytes()
    _run_cli(repo_root, db, "--audit", "--json")
    assert db.read_bytes() == before


def test_handle_resolves_through_chat_when_handle_id_is_unset(repo_root, fixture_messages):
    """Messages leaves message.handle_id = 0 on ~half of all outgoing rows.

    ROWID 402 is seeded that way. A handle filter that only matched
    `handle.id` would drop it — and with it most outgoing traffic on a real
    chat.db, which is exactly the population this vector reports on.
    """
    module = _load_module(repo_root)

    rows = _by_rowid(_fetch_all(module, fixture_messages))
    assert rows[402].handle == "+15551234567"
    assert rows[402].handle_source == "chat"
    assert rows[400].handle_source == "handle"

    filtered = _fetch_all(module, fixture_messages, handle="+15551234567")
    assert 402 in {r.rowid for r in filtered}


def _synthetic_run(module, template, states, group=False):
    """Build a newest-first run of outgoing rows in the given read states."""
    import dataclasses

    records = []
    for i, state in enumerate(states):
        records.append(dataclasses.replace(
            template,
            rowid=9000 + i,
            is_from_me=True,
            service="iMessage",
            is_group_chat=group,
            sent_at_ns=template.sent_at_ns - i * 1_000_000_000,
            read_state=state,
            read_at_ns=1 if state == "timestamped" else 0,
            read_latency_seconds=5.0 if state == "timestamped" else None,
        ))
    return records


def test_inference_headline_follows_the_dominant_explanation(repo_root, fixture_messages):
    """A 119-vs-3 run should not read as ambiguous — but must still show both."""
    module = _load_module(repo_root)
    template = _by_rowid(_fetch_all(module, fixture_messages))[400]

    lopsided_none = _synthetic_run(
        module, template, ["none"] * 10 + ["flagged_only"] + ["timestamped"]
    )
    result = module.infer_receipt_trend(lopsided_none, min_run=5)
    assert result["status"] == "likely_disabled"
    assert result["run_length"] == 11
    assert "1 flagged read" in result["note"]

    lopsided_flagged = _synthetic_run(
        module, template, ["flagged_only"] * 10 + ["none"] + ["timestamped"]
    )
    result = module.infer_receipt_trend(lopsided_flagged, min_run=5)
    assert result["status"] == "flags_without_timestamps"
    assert "1 with no flag at all" in result["note"]

    even = _synthetic_run(
        module, template, ["none"] * 5 + ["flagged_only"] * 5 + ["timestamped"]
    )
    assert module.infer_receipt_trend(even, min_run=5)["status"] == "mixed"


def test_group_rows_are_excluded_from_inference_and_latency(repo_root, fixture_messages):
    """chat.db stores one date_read per group message, not one per participant."""
    module = _load_module(repo_root)
    template = _by_rowid(_fetch_all(module, fixture_messages))[400]

    group_run = _synthetic_run(module, template, ["none"] * 10, group=True)
    assert module.infer_receipt_trend(group_run, min_run=5)["status"] == "no_data"

    summary = module.summarize_thread("chat-group", group_run)
    assert summary.group_messages == 10
    assert summary.latency["count"] == 0
