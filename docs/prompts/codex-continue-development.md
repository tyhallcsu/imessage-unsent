# Codex pickup prompt — continue `imessage-unsent` development

Paste the block below into a fresh Codex (or any agent) session that has access to `gh`, `git`, and shell. The agent should clone the repo first if not already in it.

---

```
<context>
You are continuing development of `imessage-unsent`, a macOS forensics tool that recovers retracted iMessages from chat.db-wal pre-checkpoint pages. A previous AI session (Codex on a different run) has opened **draft PR #28** with ~3020 lines of foundation work spanning Phases 1–3 of the project roadmap. Your first job is to **verify PR #28's quality** before merging or building on top of it. Do not rubber-stamp.

Repo:    https://github.com/tyhallcsu/imessage-unsent (private, owner tyhallcsu)
Roadmap: https://github.com/tyhallcsu/imessage-unsent/issues/26 (pinned)
Audit:   https://github.com/tyhallcsu/imessage-unsent/pull/28 (draft)
Handoff: docs/handoffs/2026-05-01-codex-pickup.md (in the repo)
</context>

<priority_reads>
Read these in order before any tool use that mutates state:
1. AGENTS.md — hard rules. Non-negotiable.
2. README.md — schema deep-dive + byte-level WAL technique.
3. docs/handoffs/2026-05-01-codex-pickup.md — full handoff with files, decisions, pitfalls.
4. docs/agent-onboarding.md — architecture mental model + workflow loop.
5. Issue #26 — pinned roadmap with all 24 child issues.
6. PR #28 — diff and commit. The audit target.
</priority_reads>

<phase_a_audit>
Run end-to-end before forming an opinion:

  gh pr checkout 28
  make test                                  # bats + pytest against fixture
  swift build --package-path daemon
  swift test  --package-path daemon
  swift build --package-path gui
  swift test  --package-path gui
  ./scripts/recover.sh --handle '+15551234567' --work /tmp/imu-audit \
      --live tests/fixtures --no-snapshot --json | jq .

For each phase the PR claims to advance, check:

  Phase 1 (issues #2, #3, #4, #5):
    [ ] scripts/lib/*.sh match the contracts in scripts/lib/README.md
    [ ] scan.sh predicate is EXACTLY: is_from_me = 0 AND date_edited != 0 AND is_empty = 1
        (NOT date_retracted — that column is unused on Darwin 24.x)
    [ ] Synthetic fixture is PII-free (no real phone, no real GUID, no real names,
        no recovered text)
    [ ] recover.sh --json output matches issue #3's documented schema
    [ ] Recovered string length equals otr.0.le from the fixture's bplist
        (length cross-check)

  Phase 2 (issues #7, #8, #9, #10, #11):
    [ ] daemon Package.swift builds and tests pass
    [ ] FSEvents watcher coalesces events to <=1 per 250ms
    [ ] Detector runs against the snapshot db, not ~/Library/Messages/chat.db
    [ ] Archive directory writes never touch live chat.db family
    [ ] LaunchAgent plist domain is gui/$UID (user, not system)
    [ ] No code path writes to ~/Library/Messages/

  Phase 3 (issues #12, #13, #14):
    [ ] gui Package.swift builds and tests pass
    [ ] GUI talks to daemon via Unix socket only; no direct chat.db reads from GUI
    [ ] Info.plist sets LSUIElement=YES (menu bar only, no Dock icon)

  Sanitization (cross-cutting):
    [ ] No "sharmanhall" anywhere; only "sharmanhall"
    [ ] No real phone numbers (regex: \+?1?\d{10} outside fixtures using +1555... range)
    [ ] No real Apple ID emails
    [ ] No real-conversation GUIDs (e.g. anything matching the README's case study GUID prefix)
    [ ] No recovered message text content from a real run
    [ ] All commits authored by tyhallcsu <tyhallcsu@users.noreply.github.com>

Use:
  git log -p main..feat/2-macos-foundation | grep -E '<regex>'
  git log --format='%an <%ae>' main..feat/2-macos-foundation
</phase_a_audit>

<phase_b_decide_and_act>
Post a review on PR #28 with one of these outcomes:

  Outcome 1 — APPROVE-AS-IS (PR #28 is clean enough to ship):
    gh pr review 28 --approve --body "$(cat <<'EOF'
    Audit summary: <one paragraph>
    Findings: <punch list of any minor gaps as follow-up issues>
    EOF
    )"
    gh pr merge 28 --squash --delete-branch

  Outcome 2 — REQUEST CHANGES (fixable issues, fundamentally sound):
    gh pr review 28 --request-changes --body "$(cat <<'EOF'
    <specific fixes needed, file:line references>
    EOF
    )"
    Then either wait, or apply the fixes yourself in additional commits on the
    same branch (feat/2-macos-foundation).

  Outcome 3 — REQUEST SPLIT (PR mixes too much scope to review safely):
    gh pr review 28 --comment --body "$(cat <<'EOF'
    Recommending split into smaller per-issue PRs:
      - feat/02-modular-libs   →  closes #2, #3
      - feat/04-fixture        →  closes #4
      - feat/05-test-suite     →  closes #5
      - feat/07-daemon-skeleton→  closes #7
      - feat/08-fsevents       →  closes #8
      - feat/12-gui-skeleton   →  closes #12
      - ci(matrix)             →  closes #18 partially
    EOF
    )"
    gh pr close 28
    Then carve up feat/2-macos-foundation into the per-issue branches and open
    them as separate non-draft PRs.

After PR #28 settles, immediately:
  - Add .codex/, .pytest_cache/, .ruff_cache/ to .gitignore (any path used by
    AI agents that shouldn't ship).
  - Open follow-up issues for any audit findings not blocking merge.
</phase_b_decide_and_act>

<phase_c_continue_roadmap>
Once PR #28 (or splits) merge, pick the next unblocked issue per #26's order:

  1. Finish #5 if PR #28 left it partial (full bats+pytest coverage).
  2. #6 — multi-handle batch mode.
  3. Phase 2 depth: #9 (detector), #10 (archive pipeline), #11 (notifications).
  4. Phase 3 depth: #13 (history view), #14 (settings pane).
  5. Phase 4: #17 first (Notify-only default), THEN #15 (research), THEN #16 only
     if #15 green-lights.
  6. Phase 5: #18 (extend CI), #20 (signing), #19 (release pipeline), #25 (encryption).
  7. Phase 6: #21 (per-vector docs), #22 (legal/ethics), #23 (architecture diagrams).

For each issue:
  git checkout main && git pull
  git checkout -b feat/<issue-num>-<slug>
  # ... implement against the issue's acceptance criteria ...
  git -c user.email=tyhallcsu@users.noreply.github.com -c user.name=tyhallcsu \
      commit -m "feat(<area>): <summary>"
  git push -u origin feat/<issue-num>-<slug>
  gh pr create --title "<title>" --body "Closes #<N>...followup checklist..."
  # Wait for CI green, then squash-merge.
</phase_c_continue_roadmap>

<hard_rules>
NON-NEGOTIABLE — violating any of these is grounds for the user reverting your work:

  1. Credit name: ALWAYS sharmanhall. NEVER the real legal name. Applies to:
     - LICENSE copyright line
     - README footers
     - Package manifest authors (Cargo.toml, Package.swift, package.json, etc.)
     - Code comments
     - CODEOWNERS lines
     - Any "Created by:" / "Author:" / "Maintainer:" field

  2. Git identity: tyhallcsu <tyhallcsu@users.noreply.github.com>. Set per-commit:
       git -c user.email=tyhallcsu@users.noreply.github.com \
           -c user.name=tyhallcsu commit ...
     Never inherit ~/.gitconfig user.name (it may contain the real name).

  3. chat.db writes ONLY inside the explicitly opt-in #16 path with consent flow.
     Default and only-shipped behavior is read-only against snapshot copies.

  4. Never commit:
     - recovered.txt, report.txt (from real runs), msi.bin/xml, ab.bin (from real runs)
     - chat.db, chat.db-wal, chat.db-shm (real ones — fixture is OK)
     - imessage-recovery/, ~/Library/Messages/ contents
     - wal-candidates.json from a real run
     - Any phone/GUID/name from a real conversation
     The .gitignore is your safety net; verify with `git diff --cached` before
     every commit.

  5. No --no-verify, no --force-push to main, no git config --global user.name <real>.

  6. Issues labeled ethics-review-required need a second HUMAN reviewer (not another
     AI agent) before merge. CODEOWNERS will enforce once configured.

  7. Conventional commits: feat:, fix:, docs:, test:, ci:, refactor:, chore:.
     One PR per issue. Squash-merge only with `Closes #N` keyword.
</hard_rules>

<stop_and_ask>
Stop and explicitly ask the user before:
  - Any audit finding that suggests PII was committed in PR #28.
  - Any code path you'd add that writes to live ~/Library/Messages/.
  - Adding a new dependency requiring brew/cargo install on user systems.
  - License terms changing.
  - Issue #16 ("Restore" mode) work — this requires explicit per-step confirmation.
  - Any moment your read of an issue's acceptance criteria seems wrong or outdated.

Use `gh pr comment` or open a new issue with the question. Do not silently make
judgment calls on these items.
</stop_and_ask>

<success_definition>
You succeed when:
  - PR #28 is correctly merged or correctly split-and-merged with rationale recorded.
  - Phase 1 is fully complete with green CI and a passing fixture test.
  - The next 1–2 issues (Phase 2/3 depth) are in PRs progressing toward merge.
  - No PII has been committed; no real-name credits introduced.
  - Roadmap issue #26 reflects accurate progress via auto-tracked checkboxes.
  - Final reply summarizes outcomes with PR/issue URLs.
</success_definition>
```

---

## Notes for the user (you)

- The block above is self-contained — paste into any Codex/Claude/Gemini/ChatGPT agent that has `gh` + `git` + shell access.
- For Codex specifically: it will pick up `AGENTS.md` automatically (that's the convention Codex follows). The XML structure is for clarity; it doesn't disrupt Codex's parser.
- If you want to brief a non-coding agent (e.g. just for review), use only the `<context>`, `<phase_a_audit>`, and `<hard_rules>` sections — that's enough to produce a written audit without write access.
- The `--live tests/fixtures --no-snapshot` flag combo in the audit shell snippet exercises the new modular `recover.sh` against the synthetic fixture without touching the user's real `~/Library/Messages/`. Verify those flags exist on PR #28's `recover.sh` before relying on them.
