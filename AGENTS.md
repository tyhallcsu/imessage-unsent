# AGENTS.md

Conventions and conventions-only for AI coding agents (aider, Claude Code, Cursor, Codex, Devin, etc.) dropped into this repo.

## What this project is

Forensic recovery of an iMessage another user "unsent" on macOS. Reads the SQLite WAL (`~/Library/Messages/chat.db-wal`) before it gets checkpointed, extracting the original UTF-8 text. See [README.md](README.md) for the byte-level technique.

## Where to start

→ **[Issue #26 — Roadmap](https://github.com/tyhallcsu/imessage-unsent/issues/26)** is the entry point. It links every open issue, ordered by phase (v0.1 → v0.6) with explicit dependencies.

Pick the lowest-numbered unblocked issue in the lowest-numbered milestone. Read its acceptance criteria. Branch off `main`. Implement. Open a PR with `Closes #N`. Merge.

## Hard rules

These are non-negotiable. CI may not catch them all — read carefully.

1. **Never commit the real legal name** of the maintainer in any file (LICENSE, README, manifest, comments, commit author). The handle is **`sharmanhall`**. The git committer identity is **`tyhallcsu <tyhallcsu@users.noreply.github.com>`**. Do NOT inherit `~/.gitconfig`'s `user.name` if it contains a real name.

2. **Never commit recovery output containing real message content.** Specifically: `recovered.txt`, `report.txt`, `msi.bin`, `msi.xml` from a real run, `chat.db*`, `imessage-recovery/`, anything under `~/Library/Application Support/imessage-unsent/archives/`. The `.gitignore` blocks the obvious paths; verify with `git status` before committing.

3. **Never write to `~/Library/Messages/chat.db` or its WAL/SHM** outside the explicitly opt-in "Restore" path (issue #16) which is gated by user-consent UI and the safety research in #15. The default and only-shipped behavior of every script in `scripts/` is read-only against snapshot copies.

4. **No `--no-verify`, no skipping CI, no force-push to `main`.** If a hook or test fails, fix the cause.

5. **Issues labeled `ethics-review-required` need a second human reviewer** before merge. CODEOWNERS will enforce this once configured.

## Conventions

| Topic | Rule |
|---|---|
| Branch name | `feat/<issue>-<slug>`, `fix/<issue>-<slug>`, `docs/<issue>-<slug>` |
| Commit messages | Conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `ci:`, `refactor:`, `chore:` |
| PR body | Must contain `Closes #N` for the issue it implements |
| Merge style | Squash-merge only (repo is configured for this) |
| File naming | snake_case for Python, kebab-case for shell, PascalCase for Swift |
| Shell flags | `set -uo pipefail` for libraries (NOT `-e` — vectors must run independently); `set -euo pipefail` for top-level scripts |
| Python | `ruff` clean. `python3 -m py_compile` clean. No external deps unless added to a requirements file |
| Swift | macOS 13+ minimum target. SwiftUI for UI; `Combine` for daemon→UI streams |

## Test commands

```bash
# Lint everything (also runs in CI)
shellcheck scripts/recover.sh
ruff check scripts/decode.py
python -m py_compile scripts/decode.py

# Run full suite (once #4 lands)
make test
```

## Build commands (placeholders — implemented in Phase 5)

```bash
# Daemon (once #6 lands)
cd daemon && swift build

# GUI (once #11 lands)
cd gui && xcodebuild -scheme MenuBar
```

## Files you should NOT touch unless your issue explicitly says so

- `LICENSE` — only the year/holder line; never restructure
- `.github/workflows/*.yml` — issue #18 is the place to extend these
- `scripts/recover.sh` — refactor only as part of issue #2 (modular extraction)

## Files you should read before any non-trivial change

1. [README.md](README.md) — schema deep-dive, byte-level WAL forensics
2. [SECURITY.md](SECURITY.md) — scope of acceptable use
3. [docs/agent-onboarding.md](docs/agent-onboarding.md) — extended onboarding for AI agents
4. The issue's body itself — every issue has acceptance criteria and technical pointers tailored to the task

## Reporting back

When your PR is open, the body should include:

```markdown
Closes #N

## What changed
- bullet
- bullet

## Verification
- [ ] CI green
- [ ] Acceptance criteria from #N all checked
- [ ] (if applicable) tested locally on macOS Sequoia (Darwin 24.x)
- [ ] (if applicable) added/updated tests

## Out of scope
- anything intentionally deferred to another issue
```

Stop and ask the user before:
- Adding a new dependency that requires `brew`/`cargo`/system-level install.
- Changing license terms.
- Touching anything in `scripts/recover.sh` semantics that could break the recovery path on a real run.
- Merging an `ethics-review-required` PR without a second reviewer.
