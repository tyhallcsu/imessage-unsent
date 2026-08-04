# PROGRESS — imessage-unsent

Durable, human-readable snapshot of where this project actually stands. The live
dashboard (`artifacts/progress/progress.json`) is gitignored and re-derivable; **this
file is the source of truth** and survives with the repo.

- **Session:** `post-v0.5-forensics-cycle`
- **Last verified:** 2026-08-04, `main` @ `53e7462`
- **Status:** IN PROGRESS
- **Live dashboard:** `node scripts/progress-server.mjs` (prints its URL; last run `http://127.0.0.1:8766/`)
- **Exhaustive tracker:** [`docs/handoffs/IMESSAGE-UNSENT_COMPLETION_TRACKER_2026-08-04.md`](handoffs/IMESSAGE-UNSENT_COMPLETION_TRACKER_2026-08-04.md)

## Where it stands — 72%

v0.5.0 is shipped and installed locally. Eight recovery vectors are live, including
the two landed today. What remains is one open bug, CI hardening, an audit-tracker
reconciliation, and the ethics-gated phase 4–6 tranche that cannot be merged by an
agent alone.

| Signal | State | Evidence |
| --- | --- | --- |
| Tests | 412/412 passing (1 daemon skip) | `make test` → 65 bats + 57 pytest; `swift test` → 134 daemon + 156 gui, run at `53e7462` |
| Build | rc-smoke PASSED (14 steps) | `make rc-smoke VERSION=v0.0.0-smoke` |
| Lint | clean | shellcheck + ruff (rules pinned in `ruff.toml`) |
| Secret scan | clean | 0 non-noreply emails across full history; no `.eml`/`.har`/`.tsv`/`chat.db` tracked outside `tests/fixtures/` |
| Release | v0.5.0 latest | `gh release list` |
| Daemon | running, pid 34069, FDA intact | control socket reports `chat_db_readable: true` |
| Open PRs | 0 | `gh pr list --state open` |
| Open issues | 9 | `gh issue list` |

## Completed this cycle (verified)

- **#162** — Vector 8 read/delivery-receipt CLI (`scripts/read-receipts.py`), merged `5d174bc`.
  Established that `flagged_only` ("Read" with no timestamp) is **40%** of read-flagged
  outgoing messages on a real 412,924-row `chat.db` — the state Messages.app cannot express.
- **#164** — Read-receipt state recorded on retraction archives + GUI "Read before unsend"
  line, merged `fb5c5ac`. Measured first: **83/83** retracted inbound rows retain `date_read`
  after the unsend; **29** were read *before* the retraction, median gap **1.8s**.
- **#166** — Fixture SQLite version-stamp pinning + CI byte-equality guard, merged `53e7462`.
  Eliminated the dirty-tree churn that had been accidentally committed twice.
- `ruff.toml` — pinned the lint rule selection after an unpinned-ruff upgrade turned main red.
- Daemon rebuilt/reinstalled from the #164 lineage; Full Disk Access verified to have carried
  over despite the new cdhash.
- Local branch + worktree cleanup; `main` fast-forwarded to `53e7462`.

## Milestones

| ID | Issue | Title | Status |
| --- | --- | --- | --- |
| M1 | #127 | Add actionlint (+ consider zizmor) to CI | pending |
| M2 | #160 | Investigate v0.5.0 recovery failures on macOS 15.7.1 | pending |
| M3 | #96 | Reconcile audit findings tracker vs `docs/V0.5-AUDIT-REPORT.md` | pending |
| M4 | #25 | Per-archive encryption with keychain-derived key | pending |
| M5 | #22 | Legal & ethics statement | **blocked** — ethics review |
| M6 | #15 | Research: safe writes to live `chat.db` | **blocked** — ethics review |
| M7 | #16 | Experimental Restore mode (flagged off) | **blocked** — depends on #15 |

## Human-only gates

These are **not** agent decisions and must never be inferred as approved:

1. **Ethics-review-required issues (#22, #16, #15, #88)** — need a second human reviewer
   before merge, per CODEOWNERS + branch protection. An agent may draft; it must not merge.
2. **Unflagging Restore mode (#16)** — requires a consent-flow UI decision and knowingly
   breaks the Notify-only invariant in `SECURITY.md`.
3. **Release tagging** — cutting or publishing a tag is Tyler's call; an agent stops at a
   green `rc-smoke`.

## Next best action

**M1 — #127:** add actionlint to `.github/workflows/ci.yml` on a feature branch, fix what it
flags, open a PR. Smallest valuable increment and fully agent-actionable.
