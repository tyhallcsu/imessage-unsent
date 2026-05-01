<context>
Forensic recovery tool for "unsent" iMessages on macOS. The starter implementation (`scripts/recover.sh`, `scripts/decode.py`) and a 24-issue phased roadmap are on `main` — see issue #26 (pinned). An external agent (Codex) has opened **draft PR #28** that lands ~3020 added lines across 54 files: modular CLI libs (Phase 1), Swift `daemon/` LaunchAgent skeleton (Phase 2), SwiftUI `gui/` menu bar app skeleton (Phase 3), Python helpers, a synthetic fixture, basic bats+pytest tests, and an expanded CI matrix. The PR is a single 3020-line commit covering ~10 separate issues at once — it has not been audited for correctness, sanitization, or scope discipline. The receiving session's job is to verify PR #28 is worthy of merging, decide approve-as-is vs. split-into-smaller-PRs, then continue the roadmap from there.
</context>

<environment>
- macOS Sequoia (Darwin 24.x) — required runtime; verified target build.
- `gh` CLI authenticated as `tyhallcsu` (active); `essremodel` + `bigeazypartybus` also keyringed.
- Repo: https://github.com/tyhallcsu/imessage-unsent (PRIVATE).
- Branch protection on `main` is **403** (Free plan). Convention enforces itself — do not push directly to `main`.
- CI: `.github/workflows/ci.yml` (matrix: shellcheck + ruff + bats + pytest + Swift build), `release.yml` fires on `v*.*.*` tags.
- 14 labels live (phase:1-cli ... phase:6-docs, type:feature/bug/research/test/doc/infra, ethics-review-required, good-first-issue, roadmap, type:bug).
- 6 milestones (v0.1 → v0.6) — see https://github.com/tyhallcsu/imessage-unsent/milestones.
</environment>

<files>
1. `README.md` — Tier 1. Schema deep-dive + byte-level WAL technique. Macros Sequoia gotcha is top-of-fold.
2. `AGENTS.md` — Tier 1. Hard rules (credit name = `sharmanhall`, no `chat.db` writes outside #16, no `--no-verify`). **READ before any commit.**
3. `docs/agent-onboarding.md` — Tier 1. Architecture mental model + workflow loop.
4. https://github.com/tyhallcsu/imessage-unsent/issues/26 — Tier 1. **Pinned roadmap.** Phase ordering, dependency chain, working agreements.
5. https://github.com/tyhallcsu/imessage-unsent/pull/28 — Tier 1. **The unaudited Codex PR. Audit target.** Branch `feat/2-macos-foundation`. +3020 / -194 across 54 files.
6. https://github.com/tyhallcsu/imessage-unsent/pull/27 — Tier 2. Earlier kickoff scaffold for #2 (`feat/02-modular-libs`). **Probably superseded** by PR #28's lib implementation; close after PR #28 merges.
7. `scripts/recover.sh` (on PR #28's branch) — refactored thin driver sourcing `scripts/lib/*`.
8. `scripts/lib/{common,snapshot,scan,wal,decode}.sh` + `scripts/lib/{wal_extract,json_report}.py` — Phase 1 lib implementation in PR #28.
9. `daemon/Package.swift`, `daemon/Sources/`, `daemon/com.imu.watcher.plist`, `scripts/install-daemon.sh` — Phase 2 skeleton in PR #28.
10. `gui/Package.swift`, `gui/Info.plist`, `gui/Sources/IMUMenuBar*` — Phase 3 skeleton in PR #28.
11. `tests/{bats,python,fixtures}/` — test scaffold + synthetic `chat.db` (issues #4 + part of #5) in PR #28.
12. Local stash on `feat/2-macos-foundation`: `wip: fixture regen (not for commit by handoff agent)` — modifies `tests/fixtures/chat.db` (4KB→24KB) and deletes `tests/fixtures/chat.db-wal`. **Verify before popping.**
</files>

<skills_used>
- `/conversation-handoff` — produced this doc.
- `/github-repo-bootstrap` conventions inform the repo structure (already applied to `main`).
- `/github-readme-polisher` — README hero/badges/alerts already applied.
- `/claude-prompt-optimizer` — Codex pickup prompt at `docs/prompts/codex-continue-development.md`.
- Tools used: `gh issue create`, `gh pr create --draft`, `gh label create`, `gh api` for milestones, `git stash`.
</skills_used>

<decisions_made>
- Repo owner is `tyhallcsu` (NOT `essremodel`) — explicit user override.
- Visibility: `private`.
- Credit name in any committed file: **`sharmanhall`**. Never the real legal name. Applies to LICENSE, README footers, manifest authors, code comments. Memory at `~/.claude/projects/-Users-tylerhall/memory/feedback_credit_name.md`.
- Git commit identity: `tyhallcsu <tyhallcsu@users.noreply.github.com>`. Set per-commit; do not inherit `~/.gitconfig` `user.name`.
- Issue #16 (chat.db "Restore" mode) is **authorized as a tracked deliverable** but MUST stay opt-in with a consent flow. Default mode is Notify-only (#17).
- Squash-merge only. One PR per issue is the convention — PR #28 violates this; receiving session decides whether to split.
- `claude-prompt-optimizer` (not "ai-prompt-optimizer") is the actual skill name; user has used the latter as a colloquialism — both refer to the same skill.
</decisions_made>

<known_pitfalls>
- macOS Sequoia retraction predicate is `date_edited != 0 AND is_empty = 1`. The `date_retracted` column is **unused** on Darwin 24.x despite existing in the schema. Filtering on `date_retracted != 0` will silently miss every retraction. Verify PR #28's `scripts/lib/scan.sh` uses the correct predicate.
- `chat.display_name` is `NULL` for 1:1 chats. Lookup goes via `handle.id` → `chat_handle_join` → `chat`. Never search by display_name.
- `gh api user --jq '.name'` returns the **real legal name** from the GitHub profile and would dox the user. The bootstrap skill at `~/.claude/skills/github-repo-bootstrap/scripts/bootstrap-repo.sh` is patched to hardcode `sharmanhall`. Do not reintroduce the auto-derive elsewhere.
- Branch protection is 403 (Free plan). Don't try to enable it via the API — graceful fallback, conventions enforce.
- PR #28 is a single 3020-line commit. Reviewing it as one PR is impractical. Either split into ~6–10 per-issue PRs OR accept as a "foundation drop" with explicit follow-up issues for any gaps.
- `.codex/`, `.pytest_cache/`, `.ruff_cache/` are present locally as artifacts but not yet in `.gitignore` on `main`. PR #28's `.gitignore` doesn't add them either. Add as a follow-up.
- The local stash `wip: fixture regen (not for commit by handoff agent)` may contain non-deterministic fixture rebuilds. Diff before popping.
</known_pitfalls>

<open_questions>
- Should PR #28 be merged as-is (with cleanup commits on follow-up PRs) OR split into ~6–10 smaller per-issue PRs aligned with the issues it touches? User has not explicitly decided — receiving session must propose.
- Does Codex's daemon implementation hit the <500ms detection-latency target from issue #9?
- Is the synthetic fixture's `message_summary_info` plist correctly hand-crafted? `otr.0.le` length must match the recoverable text length exactly (test by running recover.sh against the fixture and checking the cross-check assertion).
- Are the daemon and GUI Swift packages signed-buildable on macOS 14 (Sonoma) or only macOS 15 (Sequoia)?
</open_questions>

<task>
1. **Read in this order before touching anything:** `AGENTS.md`, `README.md`, `docs/agent-onboarding.md`, this handoff, then issue #26.

2. **Audit PR #28** end-to-end. For each phase the PR claims to advance:
   a. **Phase 1 (issues #2, #3, #4, partial #5):**
      - `scripts/lib/*.sh` match the contracts in `scripts/lib/README.md`.
      - The retraction predicate in `scan.sh` is exactly `is_from_me = 0 AND date_edited != 0 AND is_empty = 1` (NOT `date_retracted`).
      - The synthetic fixture has no PII (no real phone numbers, no real GUIDs, no real names, no recovered text content).
      - `make test` passes locally on macOS Sequoia.
      - `recover.sh --json` against the fixture recovers a known-good string whose length equals `otr.0.le` from the fixture's bplist.
   b. **Phase 2 (issues #7, #8, #9, partial #10/#11):**
      - `swift build --package-path daemon` succeeds.
      - `swift test --package-path daemon` passes.
      - FSEvents watcher coalesces events to ≤1/250ms.
      - Detector runs on the snapshot, not the live chat.db.
      - Archive directory writes never touch `~/Library/Messages/`.
      - LaunchAgent plist is in `gui/$UID` domain (user-level, not system).
   c. **Phase 3 (issues #12, #13, #14):**
      - `swift build --package-path gui` succeeds.
      - GUI talks to the daemon only via the Unix socket; no direct chat.db reads.
      - Menu bar app is `LSUIElement=YES` (no Dock icon).
   d. **Cross-cutting sanitization:**
      - `git log -p main..feat/2-macos-foundation` searched for `\+?1\d{10}` (phone), `[0-9A-F]{8}-[0-9A-F]{4}-` (GUIDs from real conversations), real first names, real Apple ID emails. Must return nothing real.
      - No `Tyler Hall` anywhere — only `sharmanhall`.
      - No recovered message text from a real run.

3. **Decide on PR #28 strategy** and post a `gh pr review 28` with one of:
   - `--approve` + a punch-list of follow-up issues for minor gaps.
   - `--request-changes` + specific fixes (and apply them yourself if uncontroversial).
   - `--comment` recommending the PR be closed and split into ~6–10 per-issue PRs branching from `main`. List the proposed split.

4. **Update `.gitignore`** to add `.codex/`, `.pytest_cache/`, `.ruff_cache/`, and any other agent-artifact paths discovered during audit. As a small follow-up PR off `main` if PR #28 is split, or as an additional commit on PR #28's branch if approving-with-cleanup.

5. **Open follow-up issues** for any audit findings that don't already have an open issue.

6. **Continue the roadmap.** Once PR #28 (or its splits) merges, pick the next unblocked issue per #26's order. Suggested next-steps:
   a. Finish issue #5 (full bats + pytest coverage) if PR #28 left it partial.
   b. Issue #6 (multi-handle batch mode).
   c. Phase 2 depth: issues #9, #10 if skeleton is in but logic is partial.
   d. Phase 3 depth: issues #13, #14.
   e. Phase 4 #15 (research) BEFORE #16. #17 first (cheapest).
   f. Phase 5 + 6 last.
</task>

<output>
1. **A formal review on PR #28** via `gh pr review 28 --{approve|request-changes|comment} --body-file <path>` with audit findings.
2. **Either:** PR #28 merged with `gh pr merge 28 --squash --delete-branch`, **or:** PR #28 closed (without merge) and replaced with smaller per-issue PRs.
3. **Follow-up issues** for any audit gaps not blocking merge.
4. **Subsequent PRs** for whatever roadmap issue is picked next, each `Closes #N`.
5. **A short reply** summarizing audit decision + URLs of merged/opened PRs + which roadmap issue is next.
</output>

<constraints>
- MUST follow `AGENTS.md`. Re-read it if any rule below is unclear.
- DO NOT pop the stash named `wip: fixture regen (not for commit by handoff agent)` without diffing its contents and confirming PII-free.
- DO NOT merge PR #28 without auditing — it is draft for a reason.
- DO NOT bypass the consent flow for issue #16. Default mode is Notify-only.
- DO NOT skip the macOS Sequoia gotcha (`date_edited != 0 AND is_empty = 1`). Re-derive it badly and the recovery silently fails on the user's machine.
- All commits MUST use git identity `tyhallcsu <tyhallcsu@users.noreply.github.com>`. Set per-commit:
  `git -c user.email=tyhallcsu@users.noreply.github.com -c user.name=tyhallcsu commit ...`
- Credit names in any new file MUST say `sharmanhall`, never the real legal name.
- DO NOT commit anything from `imessage-recovery/`, `~/Library/Messages/`, real `chat.db*`, `recovered.txt`, real `report.txt`, real `msi.bin`, real `ab.bin`, real `wal-candidates.json`. The `.gitignore` is your safety net but verify with `git diff --cached` before every commit.
- PR #28's branch is `feat/2-macos-foundation`. Audit work stays on that branch. Subsequent issue work uses fresh per-issue branches off `main`.
- Issues labeled `ethics-review-required` need a second human reviewer before merge — that means a real human, not another AI agent.
- No `--no-verify`, no `--force-push` to `main`, no `git config --global user.name <real-name>`.
</constraints>
