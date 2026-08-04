# HANDOFF — imessage-unsent

Crash-safe state-of-record. If a session died mid-flight, start here, then **re-verify
everything** — this file is a lead, not a fact.

- **Last updated:** 2026-08-04
- **Verified position:** `main` @ `53e7462`, clean, 0 open PRs, 9 open issues
- **Status:** IN PROGRESS — v0.5.0 shipped; post-v0.5 forensics vectors landed
- **Full detail:** [`docs/PROGRESS.md`](docs/PROGRESS.md) ·
  [`docs/handoffs/IMESSAGE-UNSENT_COMPLETION_TRACKER_2026-08-04.md`](docs/handoffs/IMESSAGE-UNSENT_COMPLETION_TRACKER_2026-08-04.md)

## Resume in one command

```bash
/project-completion-loop resume
```

It rebuilds the live dashboard from git, GitHub, the test runners, and the installed
daemon. No prior transcript needed.

## Restart the dashboard

```bash
node scripts/progress-server.mjs    # prints its URL; last run http://127.0.0.1:8766/
```

`artifacts/progress/progress.json` and `events.jsonl` are gitignored runtime state. If
they are missing, the viewer falls back to `progress.seed.json` and badges itself
"seed / template" — that is the signal to run `resume`.

## Current next action

**M1 — #127:** add actionlint to `.github/workflows/ci.yml`, fix what it flags, open a PR.

## Do not do these without a human

1. Merge anything labelled `ethics-review-required` (#22, #16, #15, #88) — needs a second
   human reviewer.
2. Unflag Restore mode (#16) — needs a consent-flow UI decision; breaks the Notify-only
   invariant in `SECURITY.md`.
3. Cut or publish a release tag.
4. Write to `~/Library/Messages/chat.db`. The shipped behavior is read-only, enforced by
   `tests/bats/60-guardrail-no-chatdb-writes.bats`.
