# Agent Onboarding

Extended guide for an AI agent that's never seen this repo before. Pairs with [AGENTS.md](../AGENTS.md) (which is the rules) — this doc is the **mental model**.

## In one paragraph

`imessage-unsent` is a macOS forensics tool. When someone unsends an iMessage, Apple wipes the message body from `chat.db` on the recipient's device. But SQLite is a write-ahead-log database: the *previous* version of the message row is still sitting in `chat.db-wal` for some time before it gets checkpointed into the main file. This repo's script extracts that pre-retract bytes by searching the WAL for the message's GUID and reading the UTF-8 immediately after it. The roadmap (issue #26) turns this script into a CLI suite, a background daemon that catches retractions in real time, a menu bar GUI, and (carefully) an experimental "Restore" mode.

## The three-component architecture (planned)

```
┌─────────────────────────────────────────────────────────────────┐
│  Messages.app  →  ~/Library/Messages/chat.db (+ -wal, -shm)     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼  FSEvents
            ┌──────────────────────────────────────┐
            │  Daemon (LaunchAgent, Swift) — Phase 2│
            │  • watches chat.db-wal               │
            │  • detects retractions               │
            │  • snapshots WAL pre-checkpoint      │
            │  • shells out to scripts/recover.sh  │
            │  • posts notification                │
            └──────────────────────────────────────┘
                ▲                            │
                │ unix socket / XPC          │ writes archive
                │                            ▼
            ┌──────────────────┐    ┌─────────────────────┐
            │  Menu Bar GUI    │    │  Archive directory  │
            │  (SwiftUI) — P3  │    │  (per-event)        │
            │  • history       │    │  • chat.db snapshot │
            │  • settings      │    │  • recovery.json    │
            │  • notifications │    │  • manifest.json    │
            └──────────────────┘    └─────────────────────┘

CLI (Phase 1): the recovery primitive everything else shells out to.
```

Implementation has started for this shape:

- `scripts/recover.sh --json` is the machine-readable recovery contract.
- `daemon/` is a SwiftPM LaunchAgent package with FSEvents, detector, archive, notification, and Unix-socket API components.
- `gui/` is a SwiftPM SwiftUI menu bar package that talks to the daemon socket and leaves Messages data access to the daemon.
- `script/build_and_run.sh` builds both Swift packages and launches the GUI as a local `.app` bundle.

The CLI (Phase 1) is the recovery primitive. The daemon (Phase 2) automates *when* it runs. The GUI (Phase 3) is how the user interacts with archives.

## Why each phase exists

| Phase | Why it exists |
|---|---|
| 1 — CLI | Today the script is a 250-line monolith. Modular libs let the daemon and tests reuse the recovery primitives without forking the logic. |
| 2 — Daemon | Manual recovery requires the user to react within minutes. The daemon catches retractions in <1 second so they're never lost to WAL checkpoints. |
| 3 — GUI | Surfacing recoveries inside Messages.app is impossible (we don't ship as a Messages plugin). A menu bar app is the right macOS-native surface. |
| 4 — Anti-Retraction | The big question: should we just *show* the original (Notify-only, default) or *restore* it in chat.db (experimental, opt-in)? Issue #15 is research; #16 is implementation gated by #15; #17 codifies the safe default. |
| 5 — Distribution | Code-signed, notarized binaries so installation doesn't require disabling Gatekeeper. |
| 6 — Docs | Per-vector references and the legal/ethics statement that should land before any v1.0 release. |

## What "another AI dropping in" should do

1. **Read [README.md](../README.md).** Especially the "macOS Sequoia gotcha" warning and the "Why the WAL vector works" section. Without those you'll re-derive the byte-level technique badly.

2. **Open [issue #26 (Roadmap)](https://github.com/tyhallcsu/imessage-unsent/issues/26).** Pick a checkbox in the lowest-numbered unblocked phase.

3. **Read the issue body carefully.** Each issue has:
   - **Context** — why this matters
   - **Acceptance criteria** — checklist you must satisfy
   - **Technical pointers** — file paths, SQL hints, byte-level guidance
   - **Suggested PR scope** — what one PR closing this should contain
   - **Depends on / blocks** — dependency chain

4. **Branch:** `git checkout -b feat/<issue>-<slug>`. Branch off `main`.

5. **Implement.** Tests first if you can. The fixture (#4) once it exists makes this easy.

6. **Open the PR.** Use the template in [AGENTS.md](../AGENTS.md#reporting-back). Include `Closes #N`.

7. **Iterate on CI.** Don't merge until green.

8. **Squash-merge.** Repo enforces this (no merge-commits, no rebase-merges).

9. **Move to the next issue.** Don't try to land a phase-3 issue when phase-1 dependencies are still open.

## What to avoid

- **Don't try to ship the whole roadmap in one PR.** Each issue is sized for ~1 PR. Bigger PRs are harder to review and slower to merge.
- **Don't invent features.** If you notice something useful that isn't in an issue, open a new issue first; don't smuggle it into an existing PR.
- **Don't touch ethics-flagged behavior without explicit user input.** Specifically: writing to `chat.db`, intercepting APNS, reading another user's data. The user has authorized issue #16 as a tracked deliverable but it MUST stay opt-in with a consent flow.
- **Don't commit anything from `~/Library/Messages/`, `imessage-recovery/`, or any path containing real message content.** The `.gitignore` is your safety net but verify with `git status` before every commit.
- **Don't change credit names or commit identity.** See [AGENTS.md](../AGENTS.md#hard-rules) — `sharmanhall` for credits, `tyhallcsu <...users.noreply...>` for git identity.

## When you finish a phase

1. Tag a release: `git tag v0.1.0 && git push --tags` — fires `.github/workflows/release.yml`.
2. Update the README's "Status" badge if relevant.
3. Close the milestone (auto-closes when all issues close).
4. Open a PR for the next phase's first issue and keep going.

## When in doubt

Stop. Ask the user. The cost of pausing is much lower than the cost of:
- Touching live message data
- Committing PII
- Implementing a feature that wasn't actually wanted
- Force-pushing or rewriting history
