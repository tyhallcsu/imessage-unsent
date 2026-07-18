# Recovery vectors — technical reference

This is the per-vector technical reference for the recovery pipeline implemented in [`scripts/recover.sh`](../scripts/recover.sh) and [`scripts/lib/`](../scripts/lib/). For the conceptual "why each vector exists" overview, see [the README's "The six recovery vectors" section](../README.md#the-six-recovery-vectors).

For each vector below: what it does, where it fires from in the orchestrator, the exact code path through the helpers, the files it reads and writes (relative to `$WORK` — by default a private `mktemp -d` dir under `$TMPDIR` that is removed on exit, or the `--work DIR` you pass, which is hardened to `0700` and kept), conditions under which it returns nothing, and the non-obvious bits a future maintainer will trip over.

| Vector | Primary output                                  | Hard-fails on miss? | Role                                                        |
| ------ | ----------------------------------------------- | ------------------- | ----------------------------------------------------------- |
| 0      | `chat.db`, `chat.db-wal`, `chat.db-shm`         | Yes                 | Freezes evidence — all later vectors read from the snapshot |
| 1      | `candidates.tsv`                                | Yes                 | Picks the row to investigate                                |
| 2      | `msi.bin`, `msi.xml`                            | No                  | Confirms retraction + supplies original-text length         |
| 3      | (stderr only)                                   | No                  | Decodes `attributedBody`; usually empty by design           |
| 4      | `wal-candidates.json`, `wal-hits.txt`           | No                  | **The vector that actually recovers text**                  |
| 5      | `exporter-hits.txt`                             | No                  | Cross-check via third-party tool                            |
| 6      | `iphone-backup.json`                            | No                  | Last-resort lookup in unencrypted iPhone backups            |
| 7      | (separate CLI: `edit-history.py`)               | No                  | Recovers prior versions of **edited** messages from the `ec` chain in `message_summary_info` — distinct from the unsent flow above |

When `--json` is set, [`scripts/lib/json_report.py`](../scripts/lib/json_report.py) emits the final report from Vector 4's first candidate, falling back to Vector 6 if WAL extraction came up empty. Vectors 2, 3, and 5 are metadata/cross-check and never appear directly in the JSON `recovered.text_b64` field.

Vector 7 is intentionally a separate CLI tool, not a step in `recover.sh`, because it operates on a different predicate (`is_empty = 0` rather than `= 1`) and its source — the `ec` chronology array — sits on the row itself, so it doesn't race against WAL checkpointing. See [`scripts/edit-history.py`](../scripts/edit-history.py).

---

## Vector 0 — Freeze state immediately (snapshot)

**Purpose.** Before doing anything else, quit Messages.app and copy the live `chat.db` family to the work dir so every later vector reads a frozen, read-only snapshot. The live WAL keeps mutating; the snapshot does not.

**Triggered when.** Always, unconditionally, unless `$WORK/chat.db` already exists from a prior run — in that case the snapshot is reused and the script logs that it skipped re-snapshotting ([recover.sh](../scripts/recover.sh) around the `imu_snapshot` call site).

**Code path:**
- [`scripts/recover.sh`](../scripts/recover.sh) calls `imu_snapshot "$WORK" "$LIVE"`
- [`scripts/lib/snapshot.sh:19`](../scripts/lib/snapshot.sh) quits Messages via `osascript`, sleeps ~2s for the SQLite write locks to release, then `cp`s `chat.db`, `chat.db-wal`, `chat.db-shm` from `$LIVE` (default `~/Library/Messages`) into `$WORK`.

**Reads:**
- `~/Library/Messages/chat.db`
- `~/Library/Messages/chat.db-wal`
- `~/Library/Messages/chat.db-shm`

**Writes:**
- `$WORK/chat.db`
- `$WORK/chat.db-wal`
- `$WORK/chat.db-shm`

**Returns nothing (fatal exit) when:**
- Post-copy, `$WORK/chat.db` does not exist. The script aborts here. The most common cause is **Full Disk Access not granted** — in that case `cp` from `~/Library/Messages` silently produces an empty work dir.

**Subtleties:**
- `osascript -e 'tell application "Messages" to quit'` is best-effort (`|| true`). If Messages was already closed or refuses to quit, the script proceeds anyway.
- The 2-second sleep is empirical, not pulled from any Apple doc — macOS needs a beat to release file locks after the process exits.
- The snapshot is *the* read-only invariant the project enforces. The Notify-only guardrail bats test ([`tests/bats/60-guardrail-no-chatdb-writes.bats`](../tests/bats/60-guardrail-no-chatdb-writes.bats)) sha256s the live fixture before and after a recovery run and asserts equality.
- WAL recovery (Vector 4) is racing checkpointing on the live system. Snapshotting *fast* is what makes Vector 4 work — every second between unsend and snapshot is another second SQLite has to checkpoint and erase the pre-retraction page image.

---

## Vector 1 — Locate the chat by handle, find the candidate row

**Purpose.** Resolve the user-supplied handle (E.164 phone or Apple ID email) to a `chat.ROWID`, then list the recent inbound retracted messages in that chat — `is_from_me = 0 AND date_edited != 0 AND is_empty = 1` — and pick the candidate.

**Triggered when.** Always, after Vector 0, in single-handle mode. Batch mode (`--all-handles`, `--handles-file`) skips the per-handle locate and uses [`imu_candidate_handles`](../scripts/lib/scan.sh) + [`imu_batch_candidates_for_handle`](../scripts/lib/scan.sh) instead.

**Code path:**
- `recover.sh` → `imu_handle_rowid "$SNAP" "$HANDLE"` → [`scripts/lib/scan.sh:15`](../scripts/lib/scan.sh) — `SELECT ROWID FROM handle WHERE id = ?`
- `recover.sh` → `imu_chat_rowid "$SNAP" "$HANDLE" "$HANDLE_ROWID"` → [`scan.sh:23`](../scripts/lib/scan.sh) — tries the 1:1 chat first, falls back to most-recently-active chat containing the handle
- `recover.sh` → `imu_candidate_table "$SNAP" "$CHAT_ROWID"` → [`scan.sh:52`](../scripts/lib/scan.sh) — formats the candidates as a TSV
- `recover.sh` → `imu_find_candidate` → [`scan.sh:148`](../scripts/lib/scan.sh) — picks the first candidate (or the user-forced `--rowid`)

**Reads:** `$WORK/chat.db` (tables `handle`, `chat`, `message`, `chat_handle_join`, `chat_message_join`).

**Writes:** `$WORK/candidates.tsv`.

**Returns nothing when:**
- The handle isn't found in `handle.id` — exits.
- The handle has no chat at all — exits.
- The chat has no rows matching the retraction predicate — exits with the "no recent retracted inbound messages" message.

**Subtleties:**
- Handle resolution is an **exact match**, not LIKE. Phone must be E.164 (`+15551234567`), email must match exactly. The Messages UI sometimes shows a normalized form that differs from `handle.id`.
- The 1:1-chat preference is asymmetric on purpose. A 1:1 match is high-confidence; falling back to "most recently active group chat with this handle" risks picking the wrong conversation, but it's better than failing.
- The retraction predicate is `date_edited != 0 AND is_empty = 1`, **not** `date_retracted != 0`. macOS Sequoia's `message.date_retracted` looks like the right column but is unused. See [the README's macOS Sequoia gotcha](../README.md#macos-sequoia-24x-gotcha--read-this-first) for why.
- Apple-epoch timestamps (`message.date_edited` is nanoseconds since 2001-01-01 UTC). Convert with the helper around [scan.sh's date columns](../scripts/lib/scan.sh).

---

## Vector 2 — Decode `message_summary_info` (msi)

**Purpose.** The `message.message_summary_info` blob is a binary plist that, for retracted messages, holds the metadata: which parts (`rp`) were retracted, the original text length per part (`otr.0.le`), and the user-sent flag (`ust`). It does **not** store the original text bytes — but `otr.0.le` is the cross-check Vector 4 uses to confirm a recovered candidate is the right length.

**Triggered when.** Always, after Vector 1, when a candidate exists.

**Code path:**
- `recover.sh` uses `sqlite3` `writefile()` to dump `message.message_summary_info` for the candidate ROWID into `$WORK/msi.bin`.
- `recover.sh` runs `plutil -convert xml1 msi.bin -o msi.xml` and then `plutil -p msi.xml` to print the first ~60 lines for the human-readable log.

**Reads:** `$WORK/chat.db` (one BLOB column for one row).

**Writes:**
- `$WORK/msi.bin` — raw binary plist
- `$WORK/msi.xml` — XML-converted plist

**Returns nothing when:** The blob is empty (logged "msi blob empty"). For fully retracted messages it usually is *not* empty — emptiness here suggests Vector 1 picked the wrong row.

**Subtleties:**
- `message_summary_info` is a **binary plist** (bplist), not an NSKeyedArchiver typedstream. `plutil` handles bplist natively; never try to feed it to the typedstream decoder.
- Keys you'll see in the wild:
  - `rp` — array of retracted part indexes, e.g. `[0]`
  - `otr.<i>.le` — original text length (UTF-16 code units, but in practice = char count for the kind of text Messages handles)
  - `otr.<i>.lo` — original text origin offset
  - `ust` — `true` if the original message was user-sent
  - `amc` — attachment-metadata count
  - `ec` — edit chronology; if present, may contain nested typedstream blobs Vector 3's deep scan walks
- `otr.0.le` is the load-bearing field for confirming a Vector 4 candidate. If WAL extraction returns multiple candidates of different lengths, the one matching `otr.0.le` is almost certainly the original.

---

## Vector 3 — Decode `attributedBody` typedstream

**Purpose.** `message.attributedBody` is an NSKeyedArchiver typedstream serialization of the rich-text representation. For *non*-retracted messages it contains the body text. For retracted messages Apple zeroes it; this vector exists for completeness and for the rare case where retraction left fragments.

**Triggered when.** Always, after Vector 2, if the optional `typedstream` Python module is installed. Without that module the script logs a hint to `pip3 install --user typedstream` and skips.

**Code path:**
- `recover.sh` dumps `attributedBody` into `$WORK/ab.bin` with `sqlite3 writefile()`.
- `recover.sh` calls [`imu_decode_blobs "$AB" "$MSI"`](../scripts/lib/decode.sh) which invokes [`scripts/decode.py`](../scripts/decode.py) on both blobs.
- `decode.py` deserializes the typedstream, walks the object graph, and prints all non-boilerplate strings. It also does a "deep scan" looking for nested typedstream blobs inside `msi.bin`'s `ec` (edit chronology).

**Reads:** `$WORK/ab.bin`, `$WORK/msi.bin`.

**Writes:** Nothing on disk — output goes to stdout/stderr captured in the report log.

**Returns nothing when:**
- `ab.bin` is empty (the common case for retracted messages — logged and continued).
- The `typedstream` module isn't installed (logged once with install hint).
- The deep scan finds no nested blobs (silent — this is the normal case).

**Subtleties:**
- The decoder filters framework cruft (`NSString`, `NSAttributedString`, `NSDictionary`, etc.) so what gets printed is plausible message content rather than typedstream metadata.
- Edit chronology (`ec`) is the only place edit history *might* be preserved as typedstream blobs; in practice most users don't edit messages, only retract them, so this almost never finds anything.
- For the forensic recovery use case, Vector 3 is a near-pure formality. The bytes you want live in the WAL (Vector 4).

---

## Vector 4 — `chat.db-wal` byte forensics (the one that wins)

**Purpose.** SQLite's write-ahead log retains pre-mutation page images for some window before `wal_autocheckpoint` rewrites them into the main DB. Apple's retraction nulls the `text` column with an `UPDATE`, but the WAL frame containing the *previous* page image — with the original UTF-8 text bytes still inline next to the message GUID — is what we recover from.

**Triggered when.** Always, after Vector 3, if `chat.db-wal` exists and is non-empty.

**Code path:**
- `recover.sh` logs WAL stats: file size, approximate frame count `(WAL_SIZE - 32) / (24 + page_size)`.
- `recover.sh` runs `grep -aob "$GUID" "$WAL"` to find every byte offset where the candidate's GUID appears.
- `recover.sh` calls [`imu_extract_from_wal "$WAL" "$GUID"`](../scripts/lib/wal.sh) (TSV output for the human log) and `imu_extract_from_wal_json` (used by `--json` and batch mode), both of which shell into [`scripts/lib/wal_extract.py`](../scripts/lib/wal_extract.py).
- `wal_extract.py` for each GUID hit: skips the 36 GUID bytes, reads the next `--window` bytes (default 8192), scans forward for the typedstream magic `\x04\x0bstreamtyped` as a terminator, validates UTF-8, requires at least one printable char, and deduplicates candidates on the first 120 chars to collapse "same text from two frames."

**Reads:** `$WORK/chat.db-wal` (binary scan of the entire file).

**Writes:**
- `$WORK/wal-candidates.json` — JSON array `[{offset, length, text, text_b64}, …]` consumed by `json_report.py` and the daemon
- `$WORK/wal-hits.txt` — human-readable per-hit log

**Returns nothing when:**
- The WAL file is missing or empty (logged "WAL file empty or missing").
- `grep` finds no GUID hits — the WAL has been checkpointed past the retraction. This is the dominant failure mode in the wild and the reason Vector 0 races to snapshot.
- All GUID hits are followed by non-UTF-8 or all-control-byte garbage (filtered out by `wal_extract.py`).

**Subtleties:**
- The on-disk row format puts the `text` column value inline immediately after the 36-byte ASCII GUID. That's the entire trick — no schema parsing required, just byte arithmetic.
- The terminator `\x04\x0bstreamtyped` is the magic header of the *next* column (`attributedBody`'s typedstream), so the bytes between GUID-end and that magic are exactly the original `text`.
- Multiple GUID hits in the WAL = multiple page images of the same message at different points in its life. Older frames have the pre-retraction text; newer frames have the post-retraction empty value. Dedup-by-prefix collapses identical recoveries from adjacent frames.
- `wal_extract.py`'s read window (`--window`, default 8192 bytes) is a bounded heuristic. It was 512 bytes, which silently dropped any message whose terminator landed further out — i.e. exactly the long messages the tool most wants to recover (#110). 8 KB comfortably covers any message stored inline in a single SQLite leaf cell; the `otr.0.le` cross-check below trims any over-capture back to the true length, so a generous window is safe. When a GUID hit's text runs past the window, the extractor now logs a truncation warning to stderr instead of dropping it silently. Widen with `--window` if you have reason to expect a longer inline message.
- The cross-check is: candidate length should match Vector 2's `otr.0.le`. The README's [byte-level walkthrough](../README.md#why-the-wal-vector-works-byte-level) shows the actual 95-byte recovery from the sanitized case study.
- This is the file the daemon's `RetractionDetector` watches via FSEvents — see [`daemon/Sources/IMUCore/FSWatcher.swift`](../daemon/Sources/IMUCore/FSWatcher.swift) — so that the daemon can snapshot before SQLite checkpoints the retraction away.

### The WAL rolling snapshot buffer (issue #67)

Vector 4 wins or loses on a single thing: **was the pre-retract page still in the live `chat.db-wal` when we read it?** SQLite checkpoints the WAL into `chat.db` on its own schedule (`wal_autocheckpoint = 1000` by default — every ~1000 page changes), so the live WAL is effectively a sliding window of the most recent few seconds-to-minutes of activity. Slow unsends, long messages, and a chatty conversation all push the pre-retract page out of that window before the daemon's `RetractionDetector` ever fires.

The daemon mitigates this with a **rolling snapshot buffer** at `~/Library/Application Support/imessage-unsent/wal-history/`. Implementation in [`WALSnapshotter.swift`](../daemon/Sources/IMUCore/WALSnapshotter.swift):

- On every `chat.db-wal` change (via FSEvents + 1 Hz polling fallback), the daemon copies the *current* WAL into the buffer with a timestamped filename.
- The buffer is capped — default **30 snapshots** AND **5 minutes** of wall time, whichever is more restrictive. Older snapshots get pruned.
- When `recover.sh` runs (either ad-hoc CLI or driven by the daemon's `ArchivePipeline`), it scans **every** WAL file in `wal-history/` in addition to the live `chat.db-wal` ([`recover.sh:529-560`](../scripts/recover.sh#L529-L560)). The candidates are merged by [`wal_merge_candidates.py`](../scripts/lib/wal_merge_candidates.py) into a single `wal-candidates.json` so the downstream JSON report sees all of them.

**What this fixes:** the dominant Vector-4 failure mode where the pre-retract text was in the WAL ~30 s ago but is gone by the time the daemon archives. With the buffer, the daemon retains those 30 s of WAL state and can recover from any of them.

**What it does NOT fix:**
- Retractions that happened **before the daemon was installed** — there's no historical buffer to draw from.
- Retractions where the daemon was running but didn't have **Full Disk Access** — `open(2)` on `chat.db-wal` fails before the snapshot copy, so nothing lands in the buffer. (The Settings → Full Disk Access pane will warn when this happens.)
- Cases where the WAL was already checkpointed past the retraction *before* the buffer captured a frame containing the pre-retract page. The 30/5min cap is a backstop; if a long delay happens between the original message write and the unsend (e.g. the user reads a message hours later then the sender unsends it), the relevant WAL state is gone everywhere.

**Operational notes:**
- Buffer disk usage is bounded by the cap (default ~30 × WAL size = a few MB at most for typical conversations).
- Compacting an archive (Settings → Compact, see issue #95) preserves the recovery output but removes its `wal-history/` snapshot copy. The daemon's *live* `wal-history/` continues to roll regardless.
- The buffer makes the recovery rate strictly better; there's no failure mode it introduces. The cost is constant disk + the per-WAL-change copy.

---

## Vector 5 — `imessage-exporter` cross-check

**Purpose.** Run [ReagentX/imessage-exporter](https://github.com/ReagentX/imessage-exporter) over the snapshot as an independent parser. It won't recover text Vector 4 missed — the exporter respects Apple's scrubbing — but it confirms the message exists, the GUID is correct, and the retraction is what we think it is.

**Triggered when.** Always, after Vector 4, **only if** `imessage-exporter` is on `$PATH`. If it isn't, the script logs that the cross-check is optional and moves on.

**Code path:**
- `recover.sh` runs `imessage-exporter -f txt -o "$WORK/export" -p "$SNAP" -c full` (`|| true` — non-zero is common when attachments are missing).
- `recover.sh` `grep`s the exporter output for the candidate's GUID and for `unsent|retract` (case-insensitive).

**Reads:** `$WORK/chat.db` (the exporter does its own SQLite open).

**Writes:**
- `$WORK/export/` — the exporter's plain-text output tree
- `$WORK/exporter-hits.txt` — grep results

**Returns nothing when:**
- `imessage-exporter` isn't installed (silent skip, logged hint).
- The exporter exits non-zero (treated as soft-fail; usually means missing attachments).
- The grep finds neither the GUID nor the unsent/retract keywords.

**Subtleties:**
- The exporter is third-party; treat changes in its output format as something that can break the grep but not the recovery.
- This vector is for *confidence*, not recovery. The fact that `imessage-exporter` independently calls the message "Unsent" is the second opinion.

---

## Vector 6 — iPhone backup vector (external backups)

**Purpose.** If WAL recovery missed (the WAL was already checkpointed before the daemon could snapshot) but the user has an unencrypted iPhone backup that was taken between the message arriving and the user unsending, the phone's `sms.db` may still hold the original `text` value.

**Triggered when.** Only when `--include-iphone-backup` is passed. The flag accepts an optional explicit path; without one, the script auto-discovers under `~/Library/Application Support/MobileSync/Backup/` and any paths listed in `~/.config/imessage-unsent/iphone-backup-paths.txt`.

**Code path:**
- `recover.sh` calls [`scripts/lib/iphone_backup.py`](../scripts/lib/iphone_backup.py) with the handle, GUID, the message's `date` (sent) and `date_edited` (retracted) timestamps, the home dir, and the optional path-list config file.
- `iphone_backup.py` enumerates candidate backup roots and **filters them by mtime falling between sent and edited timestamps** — backups taken before the message arrived can't have it; backups taken after the user unsent it have already received the retraction via sync.
- For each candidate root it locates `sms.db` via three strategies in order: `Manifest.db` lookup, hard-coded file ID fallback, loose `Library/SMS/sms.db` path.
- It opens the resolved `sms.db` read-only, queries first by GUID then by `(handle, date)` DESC as a fallback, and returns a JSON result with `hit`, `text` (base64-encoded), `backup_root`, `source`, and `mtime`.

**Reads:**
- `~/Library/Application Support/MobileSync/Backup/<UUID>/Manifest.db`
- `~/Library/Application Support/MobileSync/Backup/<UUID>/Library/SMS/sms.db` (or the file-ID equivalent)
- `~/.config/imessage-unsent/iphone-backup-paths.txt` (optional)

**Writes:** `$WORK/iphone-backup.json` — always written, with `hit: true|false` and a `reason` string explaining why on miss.

**Returns nothing (`hit: false`) when:**
- No backup roots fall inside the sent/edited mtime window (`reason: "no matching iPhone backups found"`).
- A backup is found but `sms.db` can't be located in any of the resolution strategies (`reason: "sms.db not found"`).
- `sms.db` exists but the file's first 16 bytes don't match the SQLite magic `SQLite format 3\0` — i.e. the backup is **encrypted**. Decrypt the backup externally first.
- The message exists in `sms.db` but its `text` column is empty/NULL — the retraction propagated to the phone before the backup was taken (`reason: "candidate found but text is empty"`).

**Subtleties:**
- The mtime-window filter is the entire reason this vector works. Without it, you'd be scanning every historical backup for a needle that's almost certainly not there; with it, you scan only the 0–3 backups likely to have caught the original.
- Encrypted iTunes/Finder backups are the dominant blocker for users who'd otherwise benefit. The script can't decrypt them; that's a deliberate scope decision.
- The `sms.db` GUID column matches `chat.db.message.guid`, but in some iOS versions the schema differs; the fallback `(handle, date)` query handles that.
- `--include-iphone-backup` accepts an optional positional path so you can target an off-spec location: `--include-iphone-backup /Volumes/Backup/iphone-2026-04-30`.

---

## Vector 7 — `message_summary_info` edit chronology (`ec` chain)

**Purpose.** When a sender *edits* a message (Apple's 15-minute window, up to 5 edits), every prior version of that message — including the original — is preserved on the row in the `message_summary_info` BLOB as a typedstream-encoded `NSAttributedString`, with an Apple-absolute timestamp per edit. This is **distinct from the unsent/retraction recovery** Vectors 0–6 implement: an edit leaves `is_empty = 0` and the new text in `text` / `attributedBody`; the original text is hidden in `msi.ec`.

**Triggered when.** Only when the user runs the standalone tool [`scripts/edit-history.py`](../scripts/edit-history.py). It is not part of `recover.sh`'s default flow because the predicate inverts: `recover.sh` filters `is_empty = 1` (retraction); this vector requires `is_empty = 0 AND date_edited != 0`.

**Code path:**
- [`scripts/edit-history.py`](../scripts/edit-history.py) opens `chat.db` read-only (`mode=ro` SQLite URI), filters `message` rows by `date_edited != 0 AND is_empty = 0`, optionally narrowed by `--handle`, `--rowid`, or `--since`.
- For each row it loads the `message_summary_info` BLOB, decodes it as a binary plist, walks the `ec` (edit chronology) dict — keyed by message-part index, each value an array of `{d: NSDate-as-real, t: typedstream bytes}` entries.
- For each `t` blob it locates the NSString init marker `\x94\x84\x01\x2b`, reads the typedstream length prefix (1, 3, or 5 bytes depending on string length), and extracts the UTF-8 payload up to the `\x86` element terminator. **No optional Python deps required** — the byte pattern is stable across Sequoia builds.
- A fallback regex extractor handles edge cases where the length prefix is malformed (rich-text edits, attachments, mentions).

**Reads:**
- `~/Library/Messages/chat.db` (or `--db PATH`)

**Writes:** nothing to disk; report goes to stdout (text or `--json`).

**Returns nothing when:**
- The row's `message_summary_info` is NULL or has no `ec` key — happens when the message was never edited, or when an edit-then-unsend sequence cleared the chronology (full retraction overwrites `msi`).
- The `ec` entry's `t` blob doesn't contain the NSString init marker — typically attachments, Tapbacks, or rich-text edits whose typedstream encoding differs from plain text. The decoder returns `text: null` for these but still surfaces the timestamp.
- The row was hard-deleted (Messages → Delete) before recovery — `ec` lives on the row, so deletion takes the chronology with it. Older WAL frames or the rolling snapshot buffer (issue #67) may still hold the BLOB.

**Subtleties:**
- **No WAL race.** Unlike Vector 4, this vector reads from `chat.db` directly. The chronology survives until the row is deleted or the next edit overwrites it (each edit replaces the BLOB, not appends — but the BLOB itself contains the full chain). Recovery is reliable for hours-to-days, not seconds-to-minutes.
- **Chain is cumulative within one edit window.** Up to 5 versions per message; the array preserves order with timestamps so you can replay the typing trajectory.
- **Distinct from `attributedBody` typedstream.** The `attributedBody` column holds the *current* version. The `ec.t` blobs hold *prior* versions. They share the wire format but live on different fields.
- **Read-only invariant.** The tool opens `chat.db` with `mode=ro`; covered by `tests/python/test_edit_history.py::test_readonly_invariant` which compares the file's bytes before and after the run.
- **Currently CLI-only.** The daemon does not yet detect or archive edit events — that's the scope of [issue #106](https://github.com/tyhallcsu/imessage-unsent/issues/106) follow-up work in `RetractionDetector` and `ArchivePipeline`.

---

## Limitations — when each vector fails

Each vector has a failure mode. When all of them fail it's almost always for the same underlying reason: **SQLite WAL is a rolling buffer, not an audit log.** Once iMessage commits and SQLite checkpoints the WAL into `chat.db`, the original page image is overwritten — the unsent text is no longer on disk anywhere outside external backups (Vector 6).

| Vector | Fails reliably when |
|---|---|
| 0 — snapshot | The daemon wasn't running, didn't have Full Disk Access, or the WAL was already checkpointed before the snapshot fired. |
| 1 — locate row | The handle never resolved (Apple ID typo, account merge), or the row was hard-deleted by a later sync. Rare. |
| 2 — `message_summary_info` | iMessage builds vary on whether they retain the original text in `msi`. Newer macOS often returns "metadata only" — the plist is present but the `text` field is missing. **Cannot be relied on.** |
| 3 — `attributedBody` typedstream | Retraction clears `attributedBody` to a 0-byte blob. This vector only works if the WAL still has a frame containing the pre-retract value (issue #67) — i.e. if the unsend was very recent. |
| 4 — `chat.db-wal` byte forensics | The pre-retract page is no longer in the WAL. Long messages and slow unsends are the dominant cause: more time → higher chance of an intervening checkpoint. The rolling snapshot buffer at `~/Library/Application Support/imessage-unsent/wal-history/` mitigates but does not eliminate this. |
| 5 — `imessage-exporter` cross-check | Same root cause as Vector 4 — operates on the same `chat.db` post-retract. Useful as a sanity check, not as a primary vector. |
| 6 — external backups | No backup exists for the relevant time window, or the iTunes/Finder backup is encrypted (this tool cannot decrypt). Time Machine and APFS local snapshots are the most reliable subset when configured. |
| 7 — `ec` edit chronology | The message was unsent (full retraction wipes `msi.ec`), the row was hard-deleted, or the edit was a non-text content type (attachment, Tapback) whose typedstream encoding doesn't follow the plain-text NSString pattern. Plain-text edits recover reliably for the lifetime of the row. |

### Practical guidance to maximize recovery rate

1. **Install the daemon and grant Full Disk Access before you ever need it.** The daemon's rolling WAL snapshot buffer (issue #67) is the single biggest win. Without it, recovery is best-effort against whatever the live WAL happens to look like at the moment you query it.
2. **Run the recovery as soon as possible after the unsend.** Each subsequent iMessage write moves more frames into the WAL and increases the chance of `wal_autocheckpoint` (≈ 4 MB) firing.
3. **Don't restart Messages or sign out of iCloud after an unsend you want to recover.** Restarts often trigger a synchronous checkpoint of the WAL.
4. **Enable Time Machine.** A daily backup catches anything Vectors 0–5 miss.
5. **For audit-grade recovery, replay messages off an iPhone backup** (Vector 6) — the iPhone's `sms.db` updates on its own schedule and may have the original text long after the Mac's `chat.db` has retracted it.

The tool intentionally does not promise reliability. It's a forensics tool: it will recover the message *when it can*, write a clean failure record when it can't, and never lie about the difference.

## Cross-references

- Conceptual overview of all six vectors: [README — The six recovery vectors](../README.md#the-six-recovery-vectors)
- Why Vector 4 works at the byte level: [README — Why the WAL vector works (byte-level)](../README.md#why-the-wal-vector-works-byte-level)
- The Notify-only invariant and how it's enforced across all vectors: [SECURITY.md — Operating mode](../SECURITY.md#operating-mode--notify-only)
- The daemon that automates Vectors 0–4: [daemon/Sources/IMUCore/](../daemon/Sources/IMUCore/) (in particular [`FSWatcher.swift`](../daemon/Sources/IMUCore/FSWatcher.swift), [`RetractionDetector.swift`](../daemon/Sources/IMUCore/RetractionDetector.swift), [`ArchivePipeline.swift`](../daemon/Sources/IMUCore/ArchivePipeline.swift), [`WALSnapshotter.swift`](../daemon/Sources/IMUCore/WALSnapshotter.swift))
