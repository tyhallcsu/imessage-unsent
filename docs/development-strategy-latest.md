# Development Strategy Review — `imessage-unsent`

> Forward-looking strategy review. Written 2026-05-04 against live GitHub state.
> Pairs with [docs/project-review-2026-05-04.md](project-review-2026-05-04.md)
> (validation snapshot) and [docs/ai-handoff-latest.md](ai-handoff-latest.md)
> (session continuation note).

## Date

2026-05-04 (afternoon, MDT)

## Repo State

| Field | Value |
|---|---|
| Current branch | `chore/asset-polish-and-review-notes` (PR [#78](https://github.com/tyhallcsu/imessage-unsent/pull/78)) |
| Latest commit | `4364f1a docs: update AI handoff for continued development` |
| Working tree | clean |
| Default branch | `main` @ `844929c` |
| Remote | `https://github.com/tyhallcsu/imessage-unsent.git` |
| Local validation | `make shellcheck` ✓ · `xmllint assets/*.svg` ✓ · `swift build` (daemon + gui) ✓ |
| CI on PR #78 | 7/7 green (shellcheck, ruff, pytest, bats, swift daemon, swift gui, README link check) |
| Local stale branches | ~17 pre-public-rewrite feature branches still on disk; harmless but eligible for cleanup |

## Open PR Review

### PR [#69](https://github.com/tyhallcsu/imessage-unsent/pull/69) — `docs: add CLAUDE.md`
- **Branch**: `docs/claude-md-handoff`
- **Purpose**: Add a top-level `CLAUDE.md` 5-minute orientation brief for any AI agent picking up the repo.
- **Files** (1): `CLAUDE.md` (new, +124).
- **CI**: green.
- **Mergeability**: CLEAN. Zero conflict surface (single new file).
- **Risk**: trivial. Doc-only.
- **Overlaps**: none.
- **Recommendation**: **merge first**. Free win.

### PR [#78](https://github.com/tyhallcsu/imessage-unsent/pull/78) — review notes + asset polish (THIS BRANCH)
- **Branch**: `chore/asset-polish-and-review-notes`
- **Purpose**: Lands the 2026-05-04 review notes, AI handoff doc, polished SVGs, and matching README alt-text.
- **Files** (6): `README.md`, `assets/icon.svg`, `assets/hero.svg`, `assets/recovery-flow.svg`, `docs/project-review-2026-05-04.md`, `docs/ai-handoff-latest.md`.
- **CI**: 7/7 green on the latest run after the handoff push.
- **Mergeability**: CLEAN.
- **Risk**: low. No code changes.
- **Overlaps**: shares `README.md` with PRs #68 and #73 — different sections, very likely a clean 3-way merge but PR #68 may need a tiny rebase.
- **Recommendation**: **merge second**. Lays down a clean baseline so #68 / #73 can rebase cleanly.

### PR [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70) — `fix(daemon): RecoveryNotifier crash` (closes #65)
- **Branch**: `fix/65-recovery-notifier-crash`
- **Purpose**: Fixes the daemon-crashing `NSException` that fires every time a recovery succeeds (issue [#65](https://github.com/tyhallcsu/imessage-unsent/issues/65)). Adds `NotificationAuthorizationProbing` protocol + `SystemNotificationAuthorizationProbe`, queries `getNotificationSettings` (safe read) instead of `requestAuthorization` (raises NSException from non-bundled CLI).
- **Files** (2): `daemon/Sources/IMUCore/RecoveryNotifier.swift`, `RecoveryNotifierTests.swift` (+76, -5).
- **CI**: green.
- **Mergeability**: CLEAN.
- **Risk**: low. Tightly scoped to the `UserNotificationPoster` class; tests included for both denied/notDetermined paths.
- **Overlaps**: shares `RecoveryNotifier.swift` with PR #74 (different code regions: PR #70 modifies `UserNotificationPoster` ~L109+; PR #74 modifies `RecoveryNotificationBuilder` ~L64). Same-file 3-way merge expected to be clean.
- **Recommendation**: **merge third**. High-value bug fix, isolated.

### PR [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73) — `fix(daemon): clonefile(2) for archives` (closes #71) **DRAFT**
- **Branch**: `fix/71-archive-clonefile`
- **Purpose**: Two coupled changes:
  1. Replace `FileManager.copyItem` with `clonefile(2)` via new `ArchiveCloner` (APFS COW snapshots) — directly fixes [#71](https://github.com/tyhallcsu/imessage-unsent/issues/71) (50GB archive disk usage).
  2. **Adds the full app-icon bundling pipeline** — `make icon` target, new `scripts/build-app-icon.sh`, new committed `assets/MacOS_AppIcon_iMessage_Unsent.png` (RGBA with transparent corners), `CFBundleIconFile=AppIcon` in `gui/Info.plist`, integration into `scripts/build-release.sh` and `script/build_and_run.sh`, README documentation including the alpha gotcha. **This fully closes issue [#75](https://github.com/tyhallcsu/imessage-unsent/issues/75) — which was filed yesterday before this draft was inspected.**
- **Files** (11): includes new `ArchiveCloner.swift`, new `ArchiveClonerTests.swift`, new `scripts/build-app-icon.sh`, new icon source PNG, plus modifications to `Makefile`, `README.md`, `docs/release-process.md`, `gui/Info.plist`, `scripts/build-release.sh`, `script/build_and_run.sh`, `daemon/Sources/IMUCore/ArchivePipeline.swift`.
- **CI**: green.
- **Mergeability**: CLEAN, but DRAFT.
- **Risk**: medium. Touches the release pipeline and the archive copy hot path. Tests for `ArchiveCloner` cover the success / EEXIST / ENOENT cases and the unsupported-volume fallback. The icon work is purely additive — RGBA gotcha is documented.
- **Overlaps**:
  - `README.md` with PRs #68 and #78 — different sections, likely clean.
  - `daemon/Sources/IMUCore/ArchivePipeline.swift` with PR #74 — different line ranges (#73 at L108 copy/clone switch, #74 at L153/175 adding `failureCategory` field). Should merge cleanly.
- **Recommendation**: **lift out of DRAFT and merge fourth**. After merge, **close issue #75 with a reference to this PR**; #75 was filed before this PR's icon scope was discovered.

### PR [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68) — `feat(daemon+docs): WAL rolling buffer` (closes #67)
- **Branch**: `feat/67-wal-history-rolling-buffer`
- **Purpose**: Implements the rolling WAL snapshot store (30 snapshots / 5 min) so the daemon can recover slow-unsend cases where SQLite checkpoints away pre-retract pages before the daemon snapshots.
- **Files** (8): includes new `WALSnapshotter.swift`, `WALSnapshotterTests.swift`, modifications to `imu-watcher/main.swift`, `scripts/recover.sh`, `scripts/lib/wal_merge_candidates.py`, plus `README.md`, `docs/recovery-vectors.md`, **and `assets/icon.svg`** (an early icon redesign commit that has now been superseded by both PR #78's polished SVG and PR #73's PNG-based macOS app-icon work).
- **CI**: green.
- **Mergeability**: CLEAN as of now (vs `main`). Will need a rebase after PR #78 + PR #73 land because of `README.md` overlap and the now-redundant icon redesign commit.
- **Risk**: medium. Daemon hot path; touches retraction-detection sequencing. Has tests.
- **Overlaps**:
  - `assets/icon.svg` with PR #78 — PR #78's polished version supersedes the version on this branch. Resolution after merge: drop or re-author the `10f0761` commit on this branch.
  - `README.md` with PRs #73 and #78.
- **Recommendation**: **merge fifth, after rebase**. When rebasing onto post-#78/#73 main, consider dropping `10f0761 chore(assets): redesign app icon` since it's been superseded twice over (#78's SVG polish + #73's macOS PNG icon source). Body of PR #68 should also be tightened to "WAL rolling buffer only" rather than "+docs" if the icon commit is dropped.

### PR [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74) — `fix: typed RecoveryFailureCategory + UI hints` (closes #72) **DRAFT**
- **Branch**: `fix/72-recovery-failure-category`
- **Purpose**: Replaces the conflated "non-recoverable" status with a typed `RecoveryFailureCategory` enum carried end-to-end (`scripts/recover.sh` → `json_report.py` → daemon `ArchivePipeline`/`ArchiveHistoryReader`/`RecoveryNotifier` → GUI `RecoveryDetailLoader`/`RecoveryRowView`). Surfaces per-category UI hints. Closes [#72](https://github.com/tyhallcsu/imessage-unsent/issues/72).
- **Files** (17): widest scope of any open PR — adds `RecoveryFailureCategory` (in both daemon and gui targets), tests in both targets, model/view updates, scripts, Python tests.
- **CI**: green (latest 3 runs).
- **Mergeability**: CLEAN, but DRAFT.
- **Risk**: medium-high — touches many surfaces. Is the right shape, just large. Tests are present in daemon/gui/python.
- **Overlaps**:
  - `daemon/Sources/IMUCore/ArchivePipeline.swift` with PR #73 (different line ranges — clean).
  - `daemon/Sources/IMUCore/RecoveryNotifier.swift` with PR #70 (different code regions — clean).
- **Recommendation**: **lift out of DRAFT and merge sixth (last)**, after #70 (RecoveryNotifier crash fix) and #73 (which baselines `ArchivePipeline.swift`'s clonefile path). Will need a small rebase but no real conflicts expected.

## Open Issue Review

| # | Title | Category | Priority | PR | Recommendation |
|---|---|---|---|---|---|
| [#65](https://github.com/tyhallcsu/imessage-unsent/issues/65) | RecoveryNotifier crashes daemon with uncaught NSException | bug, daemon | high | [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70) | merge #70; auto-closes |
| [#67](https://github.com/tyhallcsu/imessage-unsent/issues/67) | WAL pre-retract page gone before snapshot | bug, daemon, recovery rate | high | [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68) | merge #68; auto-closes |
| [#71](https://github.com/tyhallcsu/imessage-unsent/issues/71) | Archive snapshots use ~50GB disk | bug, daemon, disk | medium-high | [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73) | merge #73; auto-closes |
| [#72](https://github.com/tyhallcsu/imessage-unsent/issues/72) | "non-recoverable" conflates 5 causes | UX, daemon+gui | medium | [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74) | merge #74; auto-closes |
| [#75](https://github.com/tyhallcsu/imessage-unsent/issues/75) | gui: shipped IMUMenuBar.app has no custom icon | bug, gui+release | recommended pre-v1.0 | [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73) (covers it) | **comment on #75 noting #73 covers it; close when #73 merges** |
| [#76](https://github.com/tyhallcsu/imessage-unsent/issues/76) | docs: WAL rolling buffer needs user-facing section | docs | low | none | tackle after #68 merges; small follow-up PR |
| [#77](https://github.com/tyhallcsu/imessage-unsent/issues/77) | docs: SECURITY.md missing HMAC webhook signing | docs, security-docs | low | none | tackle anytime; small follow-up PR |
| [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16) | feat: experimental "Restore" mode (anti-retract) | research, feature | post-v1.0 | none | gated by #15 research; ethics-review-required |
| [#15](https://github.com/tyhallcsu/imessage-unsent/issues/15) | research: safe writes to live chat.db | research | post-v1.0 | none | upstream of #16; not now |
| [#22](https://github.com/tyhallcsu/imessage-unsent/issues/22) | docs: legal & ethics statement | docs | tracked | merged-via-#56 (closed PR) | verify content shipped; if so close issue |
| [#25](https://github.com/tyhallcsu/imessage-unsent/issues/25) | feat(privacy): per-archive encryption with keychain key | feature | pre-v1.0 nice-to-have | none | scope after RC; non-trivial |
| [#26](https://github.com/tyhallcsu/imessage-unsent/issues/26) | 🗺️ Roadmap meta-issue | meta | tracking | n/a | leave open, update as phases close |

## Recommended Merge Order

```
1. #69  CLAUDE.md                       (zero conflict, doc-only — free win)
2. #78  Review + asset polish + handoff (doc-only, sets clean README baseline)
3. #70  RecoveryNotifier crash fix      (isolated, fixes a daemon-crash regression)
4. #73  clonefile + macOS icon          (lift out of draft; closes #71 AND #75)
5. #68  WAL rolling buffer              (rebase; consider dropping superseded icon commit)
6. #74  Failure-category typing         (lift out of draft; small rebase against #70 + #73)
```

After this sequence, all six open PRs are closed and issues #65, #67, #71, #72, #75 are resolved. Issues #76, #77 remain as small follow-up doc PRs.

## Recommended Next Development Branch

**Continue on `chore/asset-polish-and-review-notes` for one more commit (this strategy doc), then pivot to a fresh branch for the next functional work.**

The next *functional* branch should be one of:

- **If a maintainer is available to review-and-merge soon**: nothing new — wait for the merge train above to land. Don't start parallel work that will conflict.
- **If you need to keep moving while reviews are pending**: cut a new branch `docs/76-wal-rolling-buffer-section` off `main` and write the user-facing WAL buffer doc (issue [#76](https://github.com/tyhallcsu/imessage-unsent/issues/76)). It's doc-only, won't conflict with any open PR, and is a 30-min task.
- **Alternative low-conflict task**: `docs/77-security-hmac-webhook-signing` for issue [#77](https://github.com/tyhallcsu/imessage-unsent/issues/77).

Both are useful, both are doc-only, neither blocks code reviewers.

## Release Readiness

Classification: **blocked before release-candidate**.

The four functional PRs (#70, #73, #68, #74) all fix issues that would be filed as RC blockers if a tag were cut today (daemon crash, WAL recovery hole, 50GB disk usage, conflated user-facing failure messages). Once those land, the project is **ready for release-candidate testing**.

## Pre-RC Checklist

- [ ] Merge PR #69 (CLAUDE.md)
- [ ] Merge PR #78 (review + assets + handoff)
- [ ] Merge PR #70 (RecoveryNotifier crash)
- [ ] Lift PR #73 out of DRAFT and merge (clonefile + icon — closes #71 + #75)
- [ ] Rebase + merge PR #68 (WAL buffer — closes #67); drop the superseded `10f0761` icon commit during rebase
- [ ] Lift PR #74 out of DRAFT and merge (failure categories — closes #72)
- [ ] Run `make rc-smoke VERSION=v0.3.0-rc1 OUTPUT_DIR=dist`
- [ ] Visually verify `dist/IMUMenuBar.app` shows the custom icon in Finder, Dock, and About
- [ ] Manually exercise: trigger an unsend, watch the daemon recover, verify notification fires once, no daemon crash, archive size sane
- [ ] Tag `v0.3.0-rc1` and let the `Release` workflow build/sign/notarize

## v1.0 Checklist

- [ ] All Pre-RC items.
- [ ] Close docs issues [#76](https://github.com/tyhallcsu/imessage-unsent/issues/76), [#77](https://github.com/tyhallcsu/imessage-unsent/issues/77).
- [ ] Decide on [#25](https://github.com/tyhallcsu/imessage-unsent/issues/25) (per-archive encryption) — nice-to-have for v1.0; ship if affordable, defer to v1.1 otherwise.
- [ ] Verify legal/ethics doc shipped via PR #56 ([#22](https://github.com/tyhallcsu/imessage-unsent/issues/22)) actually landed; if so, close [#22](https://github.com/tyhallcsu/imessage-unsent/issues/22).
- [ ] Decide whether [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16) (anti-retract Restore mode) and [#15](https://github.com/tyhallcsu/imessage-unsent/issues/15) (write research) are v1.0 or post-v1.0. Ethics review required either way.
- [ ] One real-user dogfood pass on a clean macOS install: install via release artifact, grant FDA, trigger an unsend, verify recovery, verify notification, uninstall.
- [ ] Update [#26](https://github.com/tyhallcsu/imessage-unsent/issues/26) roadmap to reflect v1.0 closure.
- [ ] Tag `v1.0.0`.

## Risks / Unknowns

- **Local Swift tests cannot run without `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`** because `xcode-select -p` points at CommandLineTools. Already documented in [docs/ai-handoff-latest.md](ai-handoff-latest.md). CI is unaffected.
- **PR #73 introduces a binary asset** (`assets/MacOS_AppIcon_iMessage_Unsent.png`, ~150KB). Not a problem in itself, but every future redesign churns the binary in git. Acceptable trade for a clean .icns pipeline.
- **PR #68's `10f0761` icon redesign commit will become noise** once #78 (polished SVG) and #73 (macOS PNG icon) land. Cleanest path is `git rebase -i` to drop it during the post-#78/#73 rebase, but **only the maintainer should do that** — destructive history rewrite on a PR branch.
- **CI does not run `make rc-smoke`** end-to-end. The release-shape build is local-only. Worth considering whether to add a manual-trigger workflow for it; not a blocker.
- **Some local branches are pre-public-rewrite cruft** (e.g. `feat/02-modular-libs`, `feat/10-archive-pipeline`, etc., all without origin tracking after the public rewrite). Safe to delete locally with `git branch -D`, but **only after confirming nothing on them is still useful**.
- **Could not validate**: dogfood / end-to-end iMessage recovery flow, since that requires Full Disk Access and live messages. Always done by the maintainer.

## Next AI Prompt

> Continue development on `imessage-unsent`. Read the latest strategy doc at `docs/development-strategy-latest.md` and the AI handoff at `docs/ai-handoff-latest.md`.
>
> The current state: PR #78 (this branch) is doc-only with all CI green. The maintainer's preferred merge order is #69 → #78 → #70 → #73 → #68 (rebase) → #74. Issues #75 (icon) and #71 (clonefile) are both already covered by PR #73's draft scope.
>
> If the maintainer has merged anything since this prompt was written, run `gh pr list --state open` and `gh pr list --state merged --limit 10` first and re-evaluate.
>
> Pick ONE of the following tasks (whichever is unblocked):
>
> 1. **If PR #68 has merged**: write the user-facing "Rolling WAL snapshot buffer" section in `README.md` (and/or new `docs/wal-rolling-buffer.md`) per issue #76. Branch: `docs/76-wal-rolling-buffer-section` off latest `main`. Cover: store path (`~/Library/Application Support/imessage-unsent/wal-history/`), retention (30 snapshots / 5 min), why it improves slow-unsend recovery, how to clear it. Close #76.
>
> 2. **If PR #68 has NOT merged yet**: write the "Webhook delivery security" subsection in `SECURITY.md` per issue #77. Branch: `docs/77-security-hmac-webhook-signing` off latest `main`. Cover: header name carrying the HMAC, algorithm (HMAC-SHA256), what bytes are signed, replay-protection status (none — say so honestly), and 5–10 lines of pseudocode for verification. Close #77.
>
> Both tasks are doc-only and won't conflict with any open PR. Do not attempt to merge any PRs yourself. Do not duplicate existing issues.
