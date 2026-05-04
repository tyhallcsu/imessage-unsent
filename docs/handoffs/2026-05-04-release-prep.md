# Release Prep Handoff — 2026-05-04

<context>
`imessage-unsent` is a macOS menu-bar app + LaunchAgent daemon that recovers retracted iMessages by reading the SQLite WAL before checkpoint. Repo: `https://github.com/tyhallcsu/imessage-unsent`. Owner: Tyler Hall (`tyhallcsu`). Recent sessions integrated a real macOS app icon — RGBA PNG source, sips/iconutil generator, full build-pipeline wiring, alpha-correct .icns at every stage, validated end-to-end (`make rc-smoke` 14/14, `make swift-test` 92/0). The icon work was committed as `85bd278 feat(gui): macOS app icon with transparent corners` and pushed, but it landed on `fix/71-archive-clonefile` — the branch behind PR #73, which is titled `fix(daemon): use clonefile(2) for chat.db archive snapshots (closes #71)`. PR #73 now contains both the daemon clonefile work AND the unrelated icon commit, which is the central mess to clean up. The receiving session is picking up at: split the icon commit onto its own branch, clean up PR #73, and then merge the open-PR queue toward a v0.2.0-rc1 tag.
</context>

<environment>
- Working tree: `/Users/tylerhall/Documents/GitHub/imessage-unsent`
- Platform: macOS Darwin 24.x, zsh, Bash tool runs `/bin/bash`
- `gh` CLI authenticated as `tyhallcsu`
- Squash-merge is the project convention (every merged PR shows up as one commit on main with `(#NN)` suffix)
- Conventional commits: `feat(scope):`, `fix(scope):`, `chore(scope):`, `docs(scope):`, `infra(scope):`
- Branch namespacing: `feat/`, `fix/`, `chore/`, `docs/`, `infra/`, `backup/`
</environment>

<files>
1. `docs/handoffs/2026-05-04-release-prep.md` — Tier 1. This file. The receiving session's authoritative starting point.
2. `https://github.com/tyhallcsu/imessage-unsent/pulls` — Tier 1. Live PR state — read this first before acting.
3. `docs/release-process.md` — Tier 1. How releases are cut. Read before re-tagging.
4. `scripts/build-release.sh` — Tier 1. Release artifact builder; the icon copy lives here on `fix/71-archive-clonefile`.
5. `scripts/build-app-icon.sh` — Tier 1 (lives on `fix/71-archive-clonefile`, not yet on `main`). Generator script; sips + iconutil.
6. `assets/MacOS_AppIcon_iMessage_Unsent.png` — Tier 1 (lives on `fix/71-archive-clonefile`). RGBA source, `hasAlpha: yes`, 1254×1254. Replacing it requires preserving alpha (an opaque RGB PNG renders as a black square in Finder).
7. `gui/Info.plist` — Tier 1. `CFBundleIconFile = AppIcon` is the wire-up (lives on `fix/71-archive-clonefile`).
8. `Makefile` — Tier 1. `make icon`, `make rc-smoke`, `make swift-test`, `make release VERSION=…`.
9. `.github/workflows/release.yml` — Tier 2. Triggers on `v*.*.*` tag pushes.
10. `.gitignore` — Tier 2. Note: `*_handoff.md` is gitignored. Use `docs/handoffs/<date>-<slug>.md` for any future handoff.

Read in this order: this file → PR list (`gh pr list --limit 100`) → `docs/release-process.md` → the specific files mentioned in whatever step you're executing.
</files>

<skills_used>
- `conversation-handoff` — produced this file.
- `push-all-branches` — used in the prior session to preserve local divergent branches as `backup/...` on origin.
</skills_used>

<decisions_made>
- The icon source PNG is RGBA with corners flood-filled to alpha=0 (luminance threshold 16, deep-clamp 4). The build pipeline ships the .icns via `CFBundleIconFile = AppIcon` because the project has no Xcode project / asset catalog — `actool` is not in play.
- `.icns` is regenerated at build time, not committed. `gui/.build/icon/` is gitignored under the existing `.build/` rule.
- `backup/main-pre-scrub-rewrite` (origin) preserves the v0.1.0-rc1 tag commit and the pre-history-rewrite main timeline. It stays forever as a recovery point.
- Three local-divergent branches (`chore/release-signing-status-surface`, `docs/22-legal-and-ethics`, `feat/2-modular-cli`) had their pre-rebase SHAs pushed to `backup/<original-path>` on origin. Origin's same-name branches still hold the canonical rebased work.
- v0.1.0-rc1 was published successfully on 2026-05-03; the second "failed" Release workflow run is benign (`gh release create` fails when the tag already has a release — documented in `docs/release-process.md` troubleshooting).
- Squash-merge is the merge mode. The PR title becomes the commit message on main.
</decisions_made>

<known_pitfalls>
- An RGB-only (no-alpha) PNG renders as a black square in Finder and Get Info. `sips` and `iconutil` faithfully preserve no-alpha through to the bundled .icns. Always verify with `sips -g hasAlpha assets/MacOS_AppIcon_iMessage_Unsent.png` before committing a new icon.
- `gh pr view --jq '.[]| ...'` with double-quoted backslash-escapes inside `\(...)` interpolation breaks under shell expansion. Use `--json` and pipe into `python3 -c` instead, or use a heredoc for the jq filter.
- zsh treats `"$branch:newname"` as a parameter modifier (`:r` etc.) and silently mangles refspecs. Use `"${branch}:refs/heads/${newname}"` with explicit braces, or just push by bare branch name when no rename is needed.
- `*_handoff.md` is in `.gitignore`. Don't name future handoff files with that suffix — use `docs/handoffs/YYYY-MM-DD-<slug>.md`.
- macOS Finder caches old app icons aggressively. After replacing an icon: `touch dist/.../IMUMenuBar.app && killall Finder`.
- PR #73 currently has scope-creep — its branch holds an unrelated icon commit. Do NOT squash-merge as-is or the icon work lands under a misleading commit message.
- PR #68 also has scope-creep (an `assets/icon.svg` redesign commit on top of the WAL buffer feature). Different concern from the .app icon work.
</known_pitfalls>

<open_questions>
1. Force-push `fix/71-archive-clonefile` to drop `85bd278` (cleaner) vs revert it on the branch (no force-push, but adds a revert commit to the open PR's commit list)? Recommendation is force-push since it's a draft PR with single-author single-reviewer scope, but Tyler must explicitly approve.
2. PR #68's `assets/icon.svg` redesign — fold into the new `feat/app-icon` branch alongside the .app icon work, split to its own branch, or accept it on PR #68 as scope-creep?
3. After Step 4 diffs confirm the local-divergent branches' originals on origin hold the canonical rebased work, retire the local branches and the matching `backup/...` safety branches on origin?
</open_questions>

<task>
Execute the recommended path forward in order. Do not start a step until the prior step is committed and pushed.

1. **Verify state.** Run `git status`, `git branch -vv`, `gh pr list --limit 100`, `gh pr view 73 --json commits,files`. Confirm `85bd278` is still on `origin/fix/71-archive-clonefile` and PR #73 still contains the icon commit.

2. **Split the icon commit onto a new branch.** Confirm with Tyler before pushing.
   ```bash
   git fetch origin
   git checkout -b feat/app-icon origin/main
   git cherry-pick 85bd278
   git push -u origin feat/app-icon
   gh pr create --base main --head feat/app-icon --draft \
     --title "feat(gui): macOS app icon with transparent corners" \
     --body "..."   # see prior advisory for body content
   ```

3. **Clean PR #73 — Tyler picks one.** Confirm before executing.
   - **Option A (cleanest, force-push of a draft):**
     ```bash
     git checkout fix/71-archive-clonefile
     git reset --hard 8669fb5
     git push --force-with-lease origin fix/71-archive-clonefile
     ```
   - **Option B (no force-push, leaves a revert in history):**
     ```bash
     git checkout fix/71-archive-clonefile
     git revert --no-edit 85bd278
     git push origin fix/71-archive-clonefile
     ```

4. **Tyler's call: PR #68's icon SVG redesign** (commit `10f0761` on `feat/67-wal-history-rolling-buffer`). Either fold into `feat/app-icon` (cherry-pick `10f0761` onto the new branch and force-push the rolling buffer branch back to `4effbce`), split to its own branch, or leave on #68. No automatic action.

5. **Merge queue, in order. Each requires Tyler review.**
   1. PR #69 `docs/claude-md-handoff` — pure docs.
   2. PR #70 `fix/65-recovery-notifier-crash` — daemon crash fix; release-blocker.
   3. PR #74 `fix/72-recovery-failure-category` — UX (still draft; ready-for-review first).
   4. PR #73 `fix/71-archive-clonefile` — *only after Step 3*. Disk-usage blocker.
   5. PR #68 `feat/67-wal-history-rolling-buffer` — *rebase against new main first* (README.md overlap with #73).
   6. New PR from Step 2 `feat/app-icon`.

6. **Reconcile divergent backups (read-only first).** For each of `chore/release-signing-status-surface`, `docs/22-legal-and-ethics`, `feat/2-modular-cli`:
   ```bash
   git diff backup/<path> origin/<path> --stat
   ```
   If origin holds all the substantive work, propose retiring the local branch + the `backup/<path>` safety branch. Do not delete without Tyler's go-ahead.

7. **Tag v0.2.0-rc1.** After all merges land on main:
   ```bash
   git checkout main && git pull --ff-only
   make rc-smoke
   git tag v0.2.0-rc1 && git push origin v0.2.0-rc1
   ```
   Then watch the Release workflow at https://github.com/tyhallcsu/imessage-unsent/actions and publish the draft release.
</task>

<output>
- A new PR opened against `main` for the `feat/app-icon` branch (Step 2).
- A cleaned `fix/71-archive-clonefile` branch (Step 3, Tyler's path choice).
- Sequenced merges of PRs #69, #70, #74, #73 (cleaned), #68 (rebased), and the new icon PR (Step 5).
- Optionally: retired local-divergent branches + safety backups (Step 6) — only after explicit confirmation.
- A pushed `v0.2.0-rc1` tag (Step 7).

Wrap-up: at the end of execution, post a one-paragraph summary covering which PRs merged, in what order, what was deferred, and the v0.2.0-rc1 release URL if reached.
</output>

<constraints>
- Do NOT force-push `main`, ever.
- Do NOT delete any `backup/*` branch (local or remote) without explicit per-branch confirmation.
- Do NOT auto-merge PRs without Tyler's review.
- Do NOT merge PR #73 in its current pre-cleanup state.
- Do NOT close or delete PRs to resolve scope creep — split via cherry-pick, don't destroy review history.
- Do NOT run `make rc-smoke` casually — it's a multi-minute end-to-end build. Only run it before tagging or after touching the build pipeline.
- Do NOT skip CI hooks (`--no-verify`) on commits.
- Use `git push --force-with-lease`, never bare `--force`, when a force-push is approved.
- Use `${var}:refs/heads/${newname}` (explicit braces) for any rename-pushing refspec — bare `$var:newname` is mangled by zsh modifier expansion.
- Conventional-commit prefixes are mandatory; the release-notes generator categorizes by prefix.
- Squash-merge is the merge mode. Author the PR title carefully — it becomes the commit message on main.
- Before tagging a release, `git checkout main && git pull --ff-only && make rc-smoke` must succeed.
- If any precondition fails (PR closed unexpectedly, branch not where this doc says, CI red), STOP and report rather than improvising.
</constraints>
