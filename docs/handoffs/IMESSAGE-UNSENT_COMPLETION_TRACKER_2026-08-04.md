# imessage-unsent — completion tracker (2026-08-04)

Exhaustive tracker for the `post-v0.5-forensics-cycle` working session. Companion to
[`docs/PROGRESS.md`](../PROGRESS.md) (the summary) and the live dashboard at
`artifacts/progress/` (gitignored, re-derivable).

**Reconstruct, don't trust.** Every claim below was re-derived from git, GitHub, the
test runners, or the running daemon. If you are a later agent picking this up: re-run
the verification commands rather than believing this file.

---

## Verified position

```
repo    tyhallcsu/imessage-unsent
branch  main
sha     53e7462
clean   yes
worktrees  1 (no concurrent agents detected)
open PRs   0
open issues 9
release    v0.5.0 (latest)
```

Verification commands:

```bash
git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD && git status --short
git worktree list && gh pr list --state open && gh issue list --limit 30
gh release list --limit 3
```

## Verified checks

| Check | Command | Result |
| --- | --- | --- |
| Shell + Python + bats + pytest | `make test` | 65 bats, 57 pytest, all green |
| Daemon Swift | `swift test --package-path daemon` | 134 tests, 1 skipped, 0 failures |
| GUI Swift | `swift test --package-path gui` | 156 tests, 0 failures |
| Release gate | `make rc-smoke VERSION=v0.0.0-smoke` | PASSED (14 steps) |
| Secret scan | `git log --format='%ae' \| sort -u \| grep -v noreply` | 0 hits |
| PII in tree | `git ls-files \| grep -E '\.(eml\|har\|tsv)$\|chat\.db$'` | only the two `tests/fixtures/chat.db*` exceptions |

Swift suites require Xcode:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path <pkg>`

## Completed this cycle — with evidence

### #162 → PR #162, merged `5d174bc`
Vector 8 read/delivery-receipt CLI. Three-state model (`timestamped` / `flagged_only` /
`none`) replacing Messages.app's single boolean.

- **Measured**: on a live 412,924-row `chat.db`, `flagged_only` accounted for **41,454 of
  103,495** read-flagged outgoing rows (40%).
- **Non-obvious finding**: `message.handle_id` is `0` on ~45% of outgoing rows, so a
  handle filter matching only `handle.id` would silently drop most outgoing traffic.
  `--handle` therefore also resolves through chat membership, and each record carries
  `handle_source`.
- **Also landed**: `ruff.toml` pinning the lint rule selection — CI installs ruff unpinned
  and a release had widened the default rule set, turning main red with no commit.

### #163 → PR #164, merged `fb5c5ac`
Read-receipt state on retraction archives + GUI "Read before unsend" line.

- **Measured before building**: **83/83** retracted inbound rows still carry `date_read`
  after the retraction (Messages does not clear it); **29 read before / 54 after**;
  median read→retract gap **1.8s**.
- **Design decision worth preserving**: the detector probes `PRAGMA table_info(message)`
  and drops the receipt columns when absent. A hardcoded SELECT naming a missing column
  would fail every prepare and end retraction detection *silently* — trading the daemon's
  core job for metadata. `testDetectionStillWorksWhenReceiptColumnsAreAbsent` guards it.
- Manifest field is `Optional` + `decodeIfPresent`; archives predating it render
  "unknown", never "no".

### #165 → PR #166, merged `53e7462`
Fixture determinism.

- **Root cause**: not randomness — SQLite stamps `SQLITE_VERSION_NUMBER` at header
  offset 96. Exactly 2 bytes of 12,288 differed (committed 3.51.0 vs local 3.53.3).
- **What a naive fix would have missed**: page 1 carries the DB header and the fixture's
  WAL holds **five copies** of it. `normalize_wal_page_one_frames()` patches those and
  must run *before* `normalize_wal()` recomputes checksums.
- **Verified cross-version**: SQLite 3.41.2 and 3.53.3 produce byte-identical databases
  once pinned; the CI guard passed on GitHub's macOS runner.
- CI guard is a workflow step (`git diff --exit-code -- tests/fixtures/`), not bats —
  CI rebuilds the fixture before bats runs, so a bats comparison would be tautological.

### Operational
- Daemon rebuilt + reinstalled (`make daemon-install`); now pid 34069.
  **FDA carried over** despite the new cdhash — verified via the control socket
  (`chat_db_readable: true`, probed 16ms after start), not via `make doctor`, which
  probes from its own process rather than the daemon's.
- Note: `status` still reports `version: 0.5.0` — `imuDaemonVersion` is bumped at
  release time, not per-merge. Binary contents (new symbols present) confirm the build.

---

## Open milestones

### M1 — #127 · add actionlint to CI · agent-actionable
Add `rhysd/actionlint` to `.github/workflows/ci.yml`; optionally evaluate `zizmor`.
Expect it to flag existing workflow issues — fix them in the same PR.
**Acceptance**: actionlint job green on a PR; no workflow behavior change.

### M2 — #160 · v0.5.0 recovery failures on macOS 15.7.1 · agent-actionable (research)
Reported failures on Darwin 15.7.1. Start from `docs/recovery-vectors.md` failure-mode
tables and the daemon log. Note the repo's known cluster: `ArchivePipeline` subprocess
pipe-deadlock (#108) and corrupt-`state.json` crash loop (#109) per
`docs/FABLE5-ULTRACODE-REVIEW.md` §6.
**Acceptance**: reproduce or definitively rule out; document the failure mode.

### M3 — #96 · audit findings tracker · agent-actionable (docs)
`docs/V0.5-AUDIT-REPORT.md` supersedes it in practice. Reconcile and either close #96
or re-scope it to the remaining documented-only Lows.

### M4 — #25 · per-archive encryption with keychain-derived key · agent-actionable
Sizable feature. Touches `ArchivePipeline`, `ArchiveCompactor`, `RecoveryDetailLoader`.
Worth an `/ai-debate` on key handling and archive-format migration before implementing.

### M5 — #22 · legal & ethics statement · **BLOCKED**
`ethics-review-required`. An agent may draft `docs/legal-and-ethics.md`; merging needs a
second human reviewer.

### M6 — #15 · safe writes to live chat.db · **BLOCKED**
`ethics-review-required`. Research only. Directly contradicts the Notify-only invariant
until a decision is made.

### M7 — #16 · experimental Restore mode · **BLOCKED**
Depends on #15 and a consent-flow UI decision. Feature-flagged off today.

---

## Human-only gates

| Ref | Who | What |
| --- | --- | --- |
| #22 / #16 / #15 / #88 | Tyler + a second human reviewer | `ethics-review-required` — agent may draft, must not merge |
| #16 restore mode | Tyler | Unflagging requires a consent-flow UI decision and knowingly breaks the `SECURITY.md` Notify-only invariant |
| release tagging | Tyler | Cutting/publishing a tag; agent stops at a green `rc-smoke` |

## Conventions that bit us before

- Branch `feat|fix|docs|ci|chore/<issue>-<slug>`; squash-merge only; PR body needs `Closes #N`.
- Commit identity `tyhallcsu <tyhallcsu@users.noreply.github.com>` — set per-repo, do not
  inherit `~/.gitconfig`.
- `git branch -d` **refuses** squash-merged branches (tips aren't ancestors of main).
  Verify by content (`git diff origin/main <branch>`) before deleting, not by `--merged`.
- Never `--no-verify`; never force-push `main`.
- macOS Sequoia retraction predicate is `date_edited != 0 AND is_empty = 1` —
  `date_retracted` is unused on Darwin 24.x.

## Next best action

**M1 — #127.** Smallest valuable increment, fully agent-actionable, no ethics gate.
