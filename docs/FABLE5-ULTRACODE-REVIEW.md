# FABLE5 ULTRACODE Review — imessage-unsent

**Reviewer:** Claude Fable 5 (ULTRACODE multi-agent workflow + direct code reading)
**Date:** 2026-07-17
**Commit reviewed:** `main` @ `0cd20c2` (feat: v0.3.0 final polish, PR #103)
**Repository:** https://github.com/tyhallcsu/imessage-unsent (public)
**Method:** Phase-1 state reconciliation → architecture map → 7 specialist review dimensions with adversarial verification → local validation matrix → direct reading of the forensic core, daemon, and control-plane sources.

> Scope note: This review is evidence-based and read-only. No live `~/Library/Messages/chat.db` was touched; all tests ran against the deterministic synthetic fixture. No Restore-mode work was implemented. No PII was committed.

---

## 1. Executive verdict

**The project is in good shape and materially safer than its own documentation claims — the primary problems are (a) documentation that has drifted behind the code, and (b) a cluster of latent daemon-reliability defects that don't show up in the green test suite.** The read-only / Notify-only guardrails are genuinely intact in code (`RetractionDetector` opens `chat.db` with `SQLITE_OPEN_READONLY`; `RestoreModeGuard` fails closed; `ArchivePipeline` only clones/copies). No real PII or secrets are in the tree. CI is green and the release pipeline is real (signs + notarizes when secrets are present).

The findings that actually matter:

- **Reliability (High):** three independent ways the daemon can silently stop working — a `Process` pipe deadlock, no subprocess timeout, and a corrupt-`state.json` crash loop. None is caught by the current tests.
- **Forensic correctness (High/Medium):** the WAL extractor's fixed 512-byte scan window silently drops exactly the *long messages* the tool most wants to recover, and both the poll fallback and the rolling snapshot buffer key change-detection on file **size only**, so they go blind to the post-checkpoint steady state.
- **Security posture (Medium):** the CLI writes the full `chat.db` snapshot and recovered plaintext into a predictable, world-traversable `/tmp/imessage-recovery` with no permission hardening; and the control socket is **no longer read-only** (it grew `delete` and `compact` ops) while SECURITY.md still promises it "cannot mutate anything on disk."
- **Documentation drift (Medium, pervasive):** CLAUDE.md's "Currently in flight" table, the issue-#65 "un-fixed" note, the `PR #68 — pending` marker, README's control-socket allowlist, architecture.md's "not poll-driven" claim, and release-process.md's "artifacts are unsigned" are all stale.

**Release-readiness:** ship-able as a *tactical personal tool* (which it explicitly claims to be), but the three High reliability findings and the socket/README/SECURITY drift should be fixed before it is promoted as a dependable always-on daemon.

---

## 2. Authoritative repository-state snapshot

| Fact | Value |
|---|---|
| Default branch | `main` @ `0cd20c2` (clean working tree at review start) |
| Latest tag | `v0.3.0-rc1` (points at `f49a49a`); also `v0.2.1-rc1`, `v0.2.0`, `v0.1.0-rc1` |
| GitHub releases | `v0.3.0-rc1`, `v0.2.1-rc1` (both **draft/pre-release**); `latestRelease: null` |
| Open PRs | **#107** only (edit-history vector, `Closes #106`) — CI green |
| Open issues | #16, #15 (restore research, ethics-gated), #22, #25, #26 (roadmap), #88 (phase-4 research), #96 (audit tracker), #106 (edit-history, addressed by #107) |
| Milestones | v0.1–v0.3 fully closed; v0.4 (2 open), v0.5 (1 open), v0.6 (1 open) |
| App identity | `iMessage Unsent.app`, bundle `com.imessage-unsent.app`, Swift target `IMUMenuBar`, URL scheme `imu://` |
| Daemon version | `imuDaemonVersion = "0.3.0"` (hand-maintained in `Version.swift`) |
| CI | 3 ubuntu jobs (shellcheck, ruff, pytest) + 3 macOS jobs (bats, swift daemon, swift gui) + README link check — passing on `main` |
| Dev machine | macOS 26.0.1 / **Darwin 25** (all docs pin verification to macOS 15 / Darwin 24.x) |
| Git identity | set repo-local to `tyhallcsu <tyhallcsu@users.noreply.github.com>` per project rules |

**Reconciliation highlights (docs vs. reality):** issue #65 is **closed and fixed** (PRs #70, #87) but CLAUDE.md still calls it "currently un-fixed"; PR #68 is **merged** but CLAUDE.md marks `WALSnapshotter.swift` as "PR #68 — pending"; the "Currently in flight" table lists #55/#56/#63/#64/#66/#68 as open, all now closed/merged; `docs/legal-and-ethics.md` is referenced from CLAUDE.md but **does not exist**.

---

## 3. Architecture & trust-boundary map

```
                    ┌────────────────────────── user's Mac (single trust domain: same-uid) ──────────────────────────┐
                    │                                                                                                 │
  ~/Library/Messages/chat.db(-wal,-shm)  ──(read-only: SQLITE_OPEN_READONLY / sqlite3 -readonly / clonefile)──┐      │
        ▲  (Apple writes; we never write — Notify-only invariant, enforced by RestoreModeGuard)                │      │
        │                                                                                                       ▼      │
   [FSWatcher]  FSEvents + 1 Hz poll ──size-change──> [RetractionDetector] ──(date_edited!=0 AND is_empty=1)──> event  │
        │  (serial queue, single coalescer)                    │  state.json (high-water + processedGUIDs)            │
        │                                                       ▼                                                      │
   [WALSnapshotter] rolling wal-history/ buffer          [ArchivePipeline] ── clone chat.db family → archives/<ts-rowid>/ (0700)
   (30 snaps / 5 min, 0600)                                     │  └─ spawns scripts/recover.sh --json --work <archiveDir>
                                                                │        └─ 6 shell/python vectors → recovery.json (0600)
                                                                ▼
                                              [RecoveryNotifier] ── native UNUserNotification (gated on auth; skipped
                                                                │     for non-bundled daemon) + optional signed webhook
                                                                ▼
   [ControlServer] AF_UNIX socket 0600 in 0700 dir  ──ping/status/recent/delete/compact──> [IMUMenuBar GUI]
        (same-uid boundary; NO auth token)                                                    (polls; renders; deep-links imu://)
```

**Trust boundaries:** the *only* security boundary is same-uid on the local machine. The socket (mode 0600 in a 0700 dir) and the daemon archives (0700/0600) enforce it in `~/Library`. **Two places break out of that posture:** the CLI's `/tmp/imessage-recovery` default (world-traversable) and the daemon log (`~/Library/Logs/...` at default umask, contains handles+GUIDs). The socket is **not** read-only (delete/compact mutate archives) but is traversal-safe (anchored archive-id regex).

**Concurrency model:** each subsystem owns a serial `DispatchQueue`. FSEvents and the poll timer share one queue and funnel through a single-slot coalescer, so there is **no duplicate-recovery race** (dedup is also persisted before notify, PR #82). The subprocess call in `ArchivePipeline` is the concurrency weak point (see F-H1).

---

## 4. Test & CI results (local validation matrix)

Run on macOS 26.0.1 / Darwin 25, Xcode 26 (Swift 6.2.3), Python 3.9.6.

| Check | Command | Result |
|---|---|---|
| shellcheck | `make shellcheck` | ✅ PASS |
| python lint | `make python-check` | ⚠️ **BLOCKED** — `ruff` not installed locally (`make: ruff: No such file or directory`). `python3 -m py_compile` of all `PYTHON_SOURCES`: ✅ CLEAN. CI installs ruff and passes. |
| pytest | `make python-test` | ✅ 7 passed |
| bats | `bats tests/bats` | ✅ 49 passed (0 fail) |
| swift daemon | `swift test --package-path daemon` | ✅ 82 run, 1 skipped, 0 failures |
| swift gui | `swift test --package-path gui` | ✅ 117 run, 0 failures |
| rc-smoke | `make rc-smoke VERSION=v0.0.0-smoke` | ✅ 14/14 PASS (build + sign-stage + notes + doctor + artifact integrity) |

**Environmental note:** `xcode-select -p` on this machine points at CommandLineTools; Swift XCTest suites require `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Xcode present). Documented commands still match the Makefile.

---

## 5. Documentation & version-drift findings (consolidated)

| ID | File | Claim | Reality |
|---|---|---|---|
| D1 | CLAUDE.md §"Currently in flight" | #55/#56/#63/#64/#66/#68 open | All closed or merged |
| D2 | CLAUDE.md:68,114,124 | issue #65 notifier crash "currently un-fixed", "no PR yet", "good first task" | **Fixed** (PR #70 gates on auth; PR #87 skips UN center from non-bundled binaries). Verified in `RecoveryNotifier.swift`. |
| D3 | CLAUDE.md:88 | `WALSnapshotter.swift` "PR #68 — pending" | PR #68 merged 2026-05-04; file shipped |
| D4 | CLAUDE.md:80, PR #56 | `docs/legal-and-ethics.md` exists | File absent; no "not legal advice" disclaimer anywhere in tree |
| D5 | SECURITY.md:42 / README.md:523 | control socket "hard allowlist ping/status/recent", "no command surface that mutates … anything on disk" | Socket also serves `delete` (removes archive dir) and `compact` (rewrites archive). See F-M2. |
| D6 | docs/architecture.md:151 | FSWatcher "is push-driven (FSEvents) and **not** poll-driven" | A 1 Hz poll fallback exists and CLAUDE.md says it must not be removed |
| D7 | docs/architecture.md:58 / CLAUDE.md:91 | socket ops = ping/status/recent/delete | `compact` op also exists (PR #101) |
| D8 | docs/release-process.md:74 | "Current status: artifacts are unsigned"; signing "tracked in #20" | Signing implemented; `sign-release.sh` called by `build-release.sh:123`; #20 closed |
| D9 | README.md:308 | checkpoint trigger "~1000 pages, ~1 MB at 4 KB page size" | 1000×4096 ≈ **4 MB** (README:265 and recovery-vectors.md say 4 MB) |
| D10 | README.md byte-level §; socket example | extraction snippet ≠ `wal_extract.py`; status example pins `"version":"0.2.0"` | Cosmetic drift |
| D11 | OS pin (README, prereqs) | "Verified on macOS 15 / Darwin 24.x" | Retraction predicate unverified on Darwin 25 (this machine). Predicate may still hold, but the claim is now unproven on current macOS. |
| D12 | GitHub issue #26 (roadmap) | every phase checkbox `- [ ]` unchecked | v0.1–v0.3 milestones fully delivered |
| D13 | AGENTS.md build/test §, docs/code-signing.md | "placeholder" build commands / stale skip-log string | Superseded by real Makefile targets |

---

## 6. Findings by severity

Severity reflects post-verification assessment. **Confidence** = CONFIRMED (verified against code, by an adversarial verifier and/or by the reviewer directly), LIKELY (strong evidence, not exhaustively reproduced), or DRIFT (documentation vs. reality).

### CRITICAL
None. The read-only/Notify-only invariant holds; no data-loss-to-live-`chat.db`, no RCE, no cross-user exploit was found.

---

### HIGH

#### F-H1 — `ArchivePipeline.runRecovery` pipe deadlock (`waitUntilExit()` before draining pipes)
- **File/symbol:** `daemon/Sources/IMUCore/ArchivePipeline.swift:155-174` (`runRecovery`)
- **Confidence:** CONFIRMED (read directly)
- **Evidence:** `try process.run(); process.waitUntilExit()` runs *before* `stdout.fileHandleForReading.readDataToEndOfFile()`. `recover.sh`'s `log()` tees every line to stderr and also dumps the candidate table (`:402`), `plutil -p` (`:453`), decode output (`:471`), and `ls -la` (`:610`) to stderr.
- **Repro/impact:** If `recover.sh` emits more than the ~64 KB kernel pipe buffer to stdout+stderr before exiting, the child blocks in `write(2)` and `waitUntilExit()` never returns. Because `ArchivePipeline` runs on the FSWatcher serial queue, a single deadlock **freezes all detection and WAL snapshotting**, and `stop()`'s `queue.sync` hangs on shutdown — while the heartbeat (separate queue) keeps logging "healthy."
- **Proposed fix:** attach `readabilityHandler` async drains (or `DispatchIO`) to both pipes *before* `run()`, accumulate with a byte cap (e.g. 4 MB), then `waitUntilExit()`.
- **Proposed tests:** daemon test spawning a stub script that writes >128 KB to stderr then exits 0; assert `archive()` returns and captures full output.

#### F-H2 — No timeout/cancellation on the `recover.sh` child
- **File/symbol:** `ArchivePipeline.swift:138-200`
- **Confidence:** CONFIRMED
- **Evidence:** `waitUntilExit()` with no deadline; no `terminate()` anywhere in the file.
- **Impact:** A hung `recover.sh` (sqlite lock contention on the snapshot, a stuck `python3`, an iCloud/NFS-stalled `--include-iphone-backup`) blocks the watcher queue forever. `KeepAlive` never helps because the process never exits. Same blast radius as F-H1.
- **Proposed fix:** run the child on a worker queue with a semaphore deadline (e.g. 120 s), then `terminate()` → SIGKILL after grace; record `failureCategory = .scriptError` with a "timeout" error.
- **Tests:** stub script that `sleep`s past the deadline; assert the pipeline returns a timeout failure and the child is reaped.

#### F-H3 — Corrupt `state.json` bricks the daemon into a launchd crash loop
- **File/symbol:** `RetractionDetector.swift:54-61` (`DetectorStateStore.load`), `:118` (init)
- **Confidence:** CONFIRMED (read directly)
- **Evidence:** `load()` does `Data(contentsOf:)` then `JSONDecoder().decode(...)` with **no catch**; `init` rethrows → `main.swift` `run()` rethrows → `exit(1)`; `com.imu.watcher.plist` has `KeepAlive=true`.
- **Impact:** A truncated/garbage `state.json` (power loss, or the #65-era crash-respawn cycles that predate the fix) makes launchd respawn into the same `exit(1)` ~every 10 s forever. All monitoring silently stops until the user hand-deletes the file.
- **Proposed fix:** in `load()`, catch decode errors → rename to `state.json.corrupt-<ts>`, log, return a fresh `DetectorState()` (seed `lastSeenDateEdited` from "now" to avoid re-archiving old retractions).
- **Tests:** write garbage to the state URL; assert `RetractionDetector.init` succeeds, quarantines the file, and starts clean.

#### F-H4 — WAL extractor's 512-byte window silently drops long messages
- **File/symbol:** `scripts/lib/wal_extract.py:30-33` (`extract_candidates`)
- **Confidence:** CONFIRMED (read directly; reviewer-found — the WAL-forensics agent dimension was cut off by the session limit)
- **Evidence:** `after = data[offset+len(needle) : offset+len(needle)+512]; end = after.find(TYPEDSTREAM_MARKER); if end <= 0: continue`. Any recovered text whose `streamtyped` terminator lands more than 512 bytes past the GUID is not found, so the candidate is discarded.
- **Impact:** The **long-message** case — the exact scenario README's Limitations and issue #67 describe as the hard one — also fails at the *extractor* level, not only via WAL-checkpoint races. A ~470+ character message that *is* present in the WAL is dropped. The tool's honest "we can't recover long messages" story understates a limitation that is partly a trivially-widenable constant.
- **Proposed fix:** grow the window (e.g. scan to the next `streamtyped` up to a few KB, bounded), or parse the record's text serial-type length from the SQLite record header instead of a fixed window; cross-check against `otr.0.le` (already available).
- **Tests:** `tests/python/test_wal_extract.py` with a synthetic WAL buffer carrying a 600-char message; assert full recovery.

#### F-H5 — Poll fallback & rolling buffer detect WAL changes by **size only** (post-checkpoint blind spot)
- **File/symbol:** `FSWatcher.swift:175-181` (`pollWAL`); `WALSnapshotter.swift:51-54` (`snapshot`)
- **Confidence:** CONFIRMED (read directly)
- **Evidence:** `pollWAL` returns early unless `currentSize != lastReportedSize`; `snapshot()` no-ops when `currentSize == lastSnapshotSize`.
- **Impact:** After a SQLite checkpoint the WAL cursor rewinds but the file is **not truncated** (no `journal_size_limit`); it sits at high-water size while new commits overwrite frames in place. In that steady state a size-only comparator sees no change. Since the poll fallback is *the* mitigation for FSEvents dropping events under `~/Library/Messages` (issue #59), a retraction that lands in the overwrite window can go undetected and be checkpointed away — unrecoverable. The rolling buffer (issue #67) has the same blind spot one layer down, so it can hold only stale copies for the very retraction it exists to catch.
- **Proposed fix:** compare `(size, mtime)` (APFS mtime is nanosecond-granular) or a cheap hash of the 32-byte WAL header (salts/sequence change on every reset) in both places.
- **Tests:** stub file whose content changes without size change; assert a detection/snapshot fires.

---

### MEDIUM

#### F-M1 — CLI writes `chat.db` snapshot + recovered plaintext to predictable, world-traversable `/tmp` (no hardening)
- **File/symbol:** `scripts/recover.sh:54` (`WORK="/tmp/imessage-recovery"`), `:165` (`mkdir -p "$WORK"`), `scripts/lib/snapshot.sh:~32` (`cp`)
- **Confidence:** CONFIRMED (security agent + verifier; reviewer-read). Verifier downgraded High→Medium (needs co-resident local account).
- **Evidence:** no `umask`/`chmod`/`mktemp` in the CLI path; `/private/tmp` is `drwxrwxrwt`; source `chat.db` is 0644 so the plain `cp` snapshot is world-readable; `report.txt`/`wal-hits.txt` carry recovered plaintext.
- **Impact:** on a shared Mac, another local account can read the full `chat.db` snapshot and recovered text. Predictable path also enables a pre-created attacker-owned dir / planted symlinks (`mkdir -p` succeeds silently), and — worse — `recover.sh:325` *reuses* a pre-existing `$WORK/chat.db` as the forensic source, so a planted DB is silently trusted (integrity, not just disclosure). No cleanup trap leaves recovered text on disk after exit.
- **Proposed fix:** `umask 077` at the top of `recover.sh`; `mkdir -p "$WORK" && chmod 0700 "$WORK"`; refuse a pre-existing `$WORK` not owned by `$EUID`; consider defaulting under `$HOME/Library/Application Support/imessage-unsent/cli-work` or `mktemp -d`.
- **Tests:** bats asserting `$WORK` is 0700 and artifacts 0600; abort-on-foreign-owner test.

#### F-M2 — Control socket is no longer read-only; SECURITY.md/README/architecture.md say it is
- **File/symbol:** `ControlServer.swift:228-236` (`delete`/`compact` cases), `:300` (`removeItem`), `:307-341` (`makeCompact`)
- **Confidence:** CONFIRMED (reviewer-read). Primarily documentation/threat-model drift; **traversal-safe** (archive-id regex anchored `^…$`, verified in `ArchiveHistoryReader.swift:184`).
- **Impact:** SECURITY.md's "no command surface that mutates … anything on disk" is materially wrong; a same-uid process can delete/mutate forensic archives via the socket. Same-uid is the intended boundary, but the doc misleads an auditor. Not an escalation (socket already 0600 same-user).
- **Proposed fix:** update SECURITY.md/README/architecture.md/CLAUDE.md to list `delete`+`compact` as mutating ops and re-justify the same-uid model; optionally add `LOCAL_PEERCRED`/`getpeereid` defense-in-depth.
- **Tests:** a doc-vs-dispatcher lint enumerating socket ops.

#### F-M3 — `Makefile` `PYTHON_SOURCES` misses shipped modules → lint/compile gaps
- **File/symbol:** `Makefile:4`
- **Confidence:** CONFIRMED (reviewer-read)
- **Evidence:** `scripts/lib/wal_merge_candidates.py` (shipped PR #68, invoked by `recover.sh:536`) and `tests/python/test_json_report.py` are absent from `PYTHON_SOURCES`; `scripts/edit-history.py` (PR #107) will need adding too.
- **Impact:** the WAL-history *merge* core — a real recovery code path — is never ruff-linted or `py_compile`-checked in CI.
- **Proposed fix:** glob (`scripts/*.py scripts/lib/*.py tests/python/*.py`) or `ruff check scripts tests/python`.

#### F-M4 — Retry bookkeeping is unreachable (`markProcessed` advances high-water past failed events)
- **File/symbol:** `imu-watcher/main.swift:177-195`; `RetractionDetector.swift` (`markProcessed`, `detect` filter `date_edited > ?1`)
- **Confidence:** LIKELY
- **Impact:** the documented `maxAttempts=3` retry design can't fire: an event is appended to `processedEvents` and the high-water mark advances regardless of `recovered`, so `detect()`'s `date_edited > ?1` filter excludes it from any retry. Failed recoveries (WAL not yet flushed) are never retried even though the design intends up to 3 attempts.
- **Proposed fix:** only advance the high-water mark for events at/under the retry ceiling; keep sub-ceiling failures visible to `detect()`, or track a separate retry queue.

#### F-M5 — `wal-history` buffer duplicated wholesale into every archive; trim only on write activity
- **File/symbol:** `WALSnapshotter.swift:83-98` (`archiveTo`), `:75` (trim call site)
- **Confidence:** CONFIRMED (reviewer-read)
- **Impact:** up to 30 full WAL copies are `copyItem`-duplicated into each archive; `trim(now:)` runs only inside `snapshot()`, so during quiet periods stale snapshots and per-archive duplication inflate disk use (echoes the #71 class of problem the clonefile work addressed for `chat.db`).
- **Proposed fix:** `ArchiveCloner.clone` in `archiveTo`; copy only snapshots younger than `maxAge`; periodic trim from the heartbeat.

#### F-M6 — Daemon version hand-maintained with no build-time injection or tag guard
- **File/symbol:** `daemon/Sources/IMUCore/Version.swift:3`
- **Confidence:** CONFIRMED
- **Impact:** `imuDaemonVersion` is currently correct (`0.3.0`) but nothing prevents it drifting from the release tag (it was stale at `0.2.0` through the rc1 build — audit #96 noted this).
- **Proposed fix:** `build-release.sh` + `release.yml prepare` guard that fails if `imuDaemonVersion != ${VERSION#v}`; longer term, generate `Version.swift` from a single `VERSION` file/tag.

#### F-M7 — Release-notes template names a nonexistent artifact + stale test locks it in
- **File/symbol:** `scripts/release-notes.sh:111-116`; `tests/bats/70-release-scripts.bats:59-65`
- **Confidence:** CONFIRMED
- **Evidence:** template emits `IMUMenuBar-VERSION.zip` (UNSIGNED) but `build-release.sh` produces `iMessage-Unsent-VERSION.zip`; the bats test asserts the stale name, so the two drift together.
- **Proposed fix:** update template to the real name + neutral signing note; assert the actual `GUI_ZIP_NAME` prefix in the test.

#### F-M8 — `workflow_dispatch` input interpolated into `run:` before validation (template injection)
- **File/symbol:** `.github/workflows/release.yml:39` (`tag="${{ inputs.tag }}"`)
- **Confidence:** LIKELY (write-gated). The semver regex guard runs *after* the interpolation point.
- **Impact:** an actor who can trigger the workflow (repo write) could supply `x"; <cmd>; "` that executes on the runner with `contents: write` and access to Apple signing secrets in the `build-macos` job. Write-access bar → Medium.
- **Proposed fix:** pass via `env:` (`env: { INPUT_TAG: ${{ inputs.tag }} }`) and reference `"$INPUT_TAG"`; validate before use. Add `actionlint`/`zizmor` to CI.

#### F-M9 — `workflow_dispatch` rebuild ships notes/tarball from `main` HEAD, not the tagged commit
- **File/symbol:** `.github/workflows/release.yml:32-34` (prepare checkout has no `ref:`), `release-notes.sh:35` (`prev..HEAD`)
- **Confidence:** LIKELY
- **Impact:** a manual re-build of an older tag would generate a source tarball and release notes from current `main`, not the tag — inconsistent with the `build-macos` job which checks out the tag.
- **Proposed fix:** check out the verified tag in `prepare`; use `${prev_tag}..${VERSION}` in release-notes when the tag ref exists.

#### F-M10 — Test gaps on destructive/lifecycle code
- **Files:** `ArchiveCompactor.swift` (compact op, exposed on the socket) — no `ArchiveCompactorTests`, no ControlServer `compact` test; `install-daemon.sh`/`uninstall-daemon.sh` — no install→upgrade→uninstall lifecycle test (`rc-smoke` only checks presence).
- **Confidence:** CONFIRMED
- **Proposed fix:** `ArchiveCompactorTests.swift`; ControlServer `compact` op tests mirroring `delete`; `tests/bats/95-install-daemon.bats` with `HOME=$BATS_TEST_TMPDIR` + a stub `launchctl`.

#### F-M11 — Documentation drift bundle (see §5)
- CLAUDE.md in-flight table / #65 / #68-pending / missing `legal-and-ethics.md` (D1–D4); architecture.md "not poll-driven" + missing `compact` op (D6/D7); release-process.md "unsigned" (D8).
- **Confidence:** DRIFT (all verified). **This is the single highest-volume, lowest-risk cleanup and should be done first.**

---

### LOW

| ID | File | Issue | Confidence |
|---|---|---|---|
| F-L1 | `RetractionDetector.swift` `save()` | `state.json` written world-readable (no posix perms on dir/file); contains handles/GUIDs, not text | CONFIRMED |
| F-L2 | `imu-watcher/main.swift:156-158` | daemon log records `handle=` (phone/AppleID) + `guid=` in cleartext to `~/Library/Logs`; SECURITY.md data-hygiene omits this | CONFIRMED |
| F-L3 | `RecoveryNotifier.swift:278` | webhook URL scheme unvalidated; recovered text (reversible base64) can POST over `http://` | CONFIRMED |
| F-L4 | `scripts/install-daemon.sh:16` + `sign-release.sh` | daemon installed 0755 in user-writable dir, ad-hoc signed by default → no tamper resistance (mitigated by TCC cdhash binding) | CONFIRMED |
| F-L5 | `scripts/recover.sh:491-492` | GUID-occurrence count prints `1` when there are `0` WAL hits (`printf '%s\n' ""` → `wc -l` = 1) | CONFIRMED |
| F-L6 | `scripts/recover.sh:502-528` | recovered text containing a newline breaks the TSV `read` loop (wal_extract emits raw `\n`/`\r`) | LIKELY |
| F-L7 | `ArchiveCompactor.swift:96-107` | archive marked `compacted` even when a file removal fails, then refuses retry | LIKELY |
| F-L8 | `scripts/lib/wal_extract.py:48-51` | dedup by `text[:120]` collides two distinct messages sharing a 120-char prefix (one dropped) | CONFIRMED |
| F-L9 | README.md:308 | "~1 MB" should be "~4 MB" (D9) | CONFIRMED |
| F-L10 | `docs/legal-and-ethics.md` (absent) + SECURITY.md | legal citations with no "informational, not legal advice" disclaimer (D4) | DRIFT |
| F-L11 | README/AGENTS/code-signing/#26 | version-example, placeholder-command, roadmap-checkbox drift (D10/D12/D13) | DRIFT |
| F-L12 | README OS pin | "Darwin 24.x verified" unproven on Darwin 25 (D11) | DRIFT |
| F-L13 | `install-daemon.sh` | copies whole `scripts/` incl. installers/`__pycache__` into the install tree | LOW/enhancement |

---

### INFORMATIONAL (positive confirmations + minor notes)

- **INFO-1 (positive):** Notify-only invariant **confirmed** — `RetractionDetector.detect` opens with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`; `RestoreModeGuard` fails closed; `ArchivePipeline` only clones/copies. No daemon or CLI write path to live `chat.db`.
- **INFO-2 (positive):** Issue #65 notifier crash **verified fixed** — `UserNotificationPoster.post` gates on `getAuthorizationStatus` and `SystemNotificationAuthorizationProbe` short-circuits when `Bundle.main.bundleIdentifier == nil` (the daemon case), so `UNUserNotificationCenter` is never touched from the non-bundled binary.
- **INFO-3 (positive):** Webhook HMAC signing **matches SECURITY.md** exactly — HMAC-SHA256, key = `Data(secret.utf8)`, lowercase hex via `%02x`, header `X-Imu-Signature`, header omitted on empty secret.
- **INFO-4 (positive):** No real PII / legal name / secrets in the tree (maintainer handle `sharmanhall` only).
- **INFO-5:** `ControlServer` `chmod`-after-`bind` leaves a sub-millisecond window where the socket exists at default perms before `0600`; and `start()` unconditionally `unlink`s a possibly-live socket. Same-uid boundary makes this negligible.
- **INFO-6:** CI runs three separate macOS jobs per PR; the two Swift jobs could share a runner to cut billable minutes. Publish job doesn't re-verify `.sha256` sidecars before attaching artifacts.

---

## 7. False positives investigated and rejected

- **"FSEvents + poll cause duplicate recoveries."** Rejected — both paths share one serial queue and a single-slot coalescer (`FSWatcher.scheduleCoalescedCallback`), and dedup is persisted before notify (PR #82). No duplicate path found.
- **"Path traversal via socket `delete`/`compact` id."** Rejected — `archiveDirectoryNamePattern` is anchored `^\d{4}-\d{2}-\d{2}T\d{6}Z-\d+$`; `../` cannot match.
- **"Daemon posts notifications and can crash (#65)."** Rejected as current — fixed; the daemon deliberately never posts (bundle-id guard), GUI owns notifications.
- **"WAL extractor reads whole file → unbounded memory DoS."** Investigated, low-risk — WAL is bounded (~4 MB autocheckpoint) and the buffer snapshots are individually small; not a practical DoS on the intended input.
- **"SECURITY.md line 41 literally contradicted by /tmp exposure."** Partially rejected — line 41 is scoped to the *daemon socket/archives*, which are correctly isolated; the CLI `/tmp` default violates the document's *overall posture* but not that specific sentence.

---

## 8. Security & privacy assessment

The core guarantees hold: **read-only against live data, Notify-only, no cross-uid exploit, no secrets/PII in the repo.** The gaps are posture/hygiene, not escalation: (a) the CLI `/tmp` default undoes the 0700/0600 posture the daemon carefully maintains (F-M1); (b) the socket gained mutating ops the docs deny (F-M2, traversal-safe); (c) handles/GUIDs leak into the daemon log and `state.json` at default perms (F-L1/F-L2); (d) webhook allows cleartext `http://` for message content (F-L3); (e) release supply chain has a write-gated template-injection sink (F-M8). Legal docs make substantive CFAA/ECPA claims with **no "not legal advice" disclaimer** and point at a missing file (F-L10) — worth correcting for a tool of this nature.

## 9. Forensic-correctness assessment

The Sequoia predicate (`date_edited != 0 AND is_empty = 1`) is correct and consistently applied. The **honest** limitation story (README Limitations) is a real strength. But two implementation facts make recovery worse than necessary: the 512-byte extractor window drops long messages outright (F-H4), and size-only change detection blinds both the poll fallback and the rolling buffer to the post-checkpoint steady state (F-H5) — the buffer that exists specifically to beat the checkpoint race can miss the write it was built for. The msi-length cross-check (`otr.0.le`) and placeholder-filtering (`￼/�`, PR #104/#105) are sound. Confidence is communicated honestly to the user (failure categories, "not a forensics product" disclaimer). The OS pin (D11) means correctness on current macOS (Darwin 25) is asserted but unverified.

## 10. Release-readiness verdict

**Conditional GO as a tactical personal tool** (its stated identity). CI green, rc-smoke green, signing pipeline real, guardrails intact. **Before promoting it as a dependable always-on daemon**, fix F-H1/F-H2/F-H3 (silent daemon death) and reconcile F-M2/D5 + the CLAUDE.md drift so the security story in the docs matches the code. F-M8/F-M9 should be fixed before the next tagged release cut via `workflow_dispatch`.

## 11. Prioritized remediation sequence

1. **Docs reconciliation (F-M11/§5, F-M2 doc side)** — zero code risk, removes the most misleading statements. *(one docs PR)*
2. **F-H3 corrupt-state fallback** — smallest High fix, highest reliability ROI. *(fix PR + test)*
3. **F-H1 + F-H2 subprocess drain+timeout** — same file, do together. *(fix PR + tests)*
4. **F-H5 size→(size,mtime) detection** — small, high forensic value. *(fix PR + test)*
5. **F-H4 widen/parse WAL window** — forensic correctness. *(fix PR + `test_wal_extract.py`)*
6. **F-M1 CLI umask/0700 + owner check** — security hygiene. *(fix PR + bats)*
7. **F-M3 Makefile glob, F-M7 release-notes name+test, F-M6 version guard, F-M8/F-M9 release.yml** — CI/release hardening. *(small PRs)*
8. **F-M4/F-M5/F-M10 + LOW cluster** — reliability + coverage backlog.

### Remediation status — 2026-07-18 pass

All High findings and the review's Medium reliability/security/release cluster are now merged to `main` (`438714a`). Each fix shipped with deterministic regression tests; no read-only/Notify-only boundary was weakened and no Restore-mode work was done.

| Finding | Fix | PR | State |
| --- | --- | --- | --- |
| F-H3 corrupt `state.json` crash loop | quarantine + fresh state | #117 | ✅ merged |
| Docs reconciliation (§5) | stale-claim sweep | #118 | ✅ merged |
| F-M3 Makefile lint glob | `$(wildcard …)` | #119 | ✅ merged |
| **F-H1/F-H2** subprocess pipe-deadlock + no timeout | `BoundedProcessRunner` (concurrent capped drain + 120 s SIGTERM→SIGKILL) | #120 | ✅ merged |
| **F-H4** WAL 512-byte window drops long messages | bounded configurable window (8 KB, `--window`) + truncation reporting | #121 | ✅ merged |
| **F-H5** size-only WAL change detection | `WALChangeSignature` (size + ns-mtime + inode) in poll + snapshotter | #122 | ✅ merged |
| **F-M1** predictable/world-traversable `/tmp` work dir | `umask 077` + private `mktemp` dir + owner-only snapshot + cleanup trap | #123 | ✅ merged |
| **F-M6/M7/M8/M9** release-workflow hardening | env-passed dispatch input, tag checkout, artifact-name fix, version-drift guard | #125 | ✅ merged |
| Edit-history recovery (#106) | read-only `edit-history.py` (msi `ec` chain) | #107 | ✅ merged |

**New finding raised *and fixed* this pass (#124, PR #130):** an intermittent SIGTRAP crash in `ControlServerTests` during the *full* daemon suite. Root cause (ThreadSanitizer-confirmed): `ControlServer.stop()` closed the listen fd out from under a live accept `DispatchSourceRead`, and raced the `listenFD` field between the accept and lifecycle queues. Fixed by closing the fd from the source's cancel handler with a deterministic `stop()` barrier. Verified TSan-clean + 55 consecutive clean full-suite runs.

**Still open (backlog / out of scope this pass):** F-M2 socket-doc/SECURITY reconciliation (partly covered by #118), F-M4/F-M5/F-M10 and the LOW cluster, the un-run GUI/accessibility and WAL-fuzz reviews (§12), and the ethics-gated Restore-mode/encryption work (#16/#25/#88).

## 12. Things NOT verified (explicit)

- **GUI review** (SwiftUI lifecycle, deep-linking, App Doctor accuracy, VoiceOver/Dynamic Type/contrast, empty/error states) — the `swiftui-gui` review agent was terminated by the session limit. The 117 GUI unit tests pass, but accessibility and interactive behavior were **not** independently audited.
- **WAL-forensics review agent** was also cut off; F-H4/F-H5/F-L8 are the reviewer's own direct-read findings, not that agent's output. A full byte-level fuzz of frame/salt/checksum handling (which the code does not do — it is a naive GUID scan, contra README's byte-level narrative) was not performed.
- **Adversarial verification** completed for the security dimension only (IMU-01..07 verdicts); daemon/release/docs findings are reviewer-verified by direct code reading, not by a second independent agent.
- **No live-device testing** — all behavior inferred from code + synthetic fixture. Real `chat.db` recovery rates, FDA/TCC flows, and notification delivery were not exercised.
- **`ruff` lint** did not run locally (binary absent); relying on CI for that gate.
- **Restore mode (#16), encryption (#25), and other ethics-gated work** were intentionally not touched.

---

*Remediation status is tracked in §11 and updated as PRs merge. See GitHub issues cross-linked in Phase 6 for per-finding trackers.*
