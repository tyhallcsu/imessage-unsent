# AI Handoff — `imessage-unsent`

> Session-specific continuation note. Pairs with the canonical
> [AGENTS.md](../AGENTS.md) (hard rules) and the orientation brief in
> [PR #69's CLAUDE.md](https://github.com/tyhallcsu/imessage-unsent/pull/69).
> This file is the latest "where did the previous agent stop" snapshot.

## Date / Machine

- Date: 2026-05-04 (afternoon, MDT)
- Machine path: `/Users/bradbanks/Documents/GitHub/imessage-unsent`
- Repo path on prior maintainer's machine: `/Users/tylerhall/Documents/GitHub/imessage-unsent`
- macOS Darwin 25.0.0, Apple Silicon

## Git State

| Field | Value |
|---|---|
| Current branch | `chore/asset-polish-and-review-notes` |
| Latest commit on branch | will be the handoff commit; previous head was `789fee1` |
| Tracking | `origin/chore/asset-polish-and-review-notes` |
| Ahead/behind `origin/main` | 1 ahead, 0 behind (pre-handoff commit); branch was cut from current `main` head `844929c` |
| Remote URL | `https://github.com/tyhallcsu/imessage-unsent.git` |
| Open PR for this branch | [#78](https://github.com/tyhallcsu/imessage-unsent/pull/78) — open, mergeable, all 7 CI checks green |
| Default branch | `main` |

## Changes Preserved (this session)

| File | Status | Why |
|---|---|---|
| [docs/project-review-2026-05-04.md](project-review-2026-05-04.md) | committed in `789fee1` | Formal review record (validation, GitHub state, gaps). |
| [README.md](../README.md) | committed in `789fee1` | Alt-text refinements that match polished SVGs. |
| [assets/icon.svg](../assets/icon.svg) | committed in `789fee1` | Layered speech-bubble + cyan reveal design. |
| [assets/hero.svg](../assets/hero.svg) | committed in `789fee1` | Accessibility (title/desc) + minor polish. |
| [assets/recovery-flow.svg](../assets/recovery-flow.svg) | committed in `789fee1` | Accessibility (title/desc) + minor polish. |
| [docs/ai-handoff-latest.md](ai-handoff-latest.md) | this commit | Session handoff (this file). |

No untracked files. No deferred dirty changes. `git status` is clean.

## Validation Run (this session)

| Command | Result |
|---|---|
| `git status --short` | clean post-commit |
| `make shellcheck` | pass |
| `xmllint --noout assets/*.svg` | all three valid |
| `swift build --package-path daemon` | success |
| `swift build --package-path gui` | success |
| `swift test --package-path daemon` | **skipped locally** — `xcode-select -p` is `/Library/Developer/CommandLineTools` so XCTest is missing. CI runs the full test on macOS runners and is green. Override with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path daemon` (no sudo needed if Xcode is installed). |
| `swift test --package-path gui` | same — see above |
| `make rc-smoke` | not run; multi-minute. Recommended before any RC tag. |
| GitHub Actions on PR #78 | all 7 checks green (shellcheck, ruff, pytest, bats, swift daemon, swift gui, README link check) |

## GitHub State

### Open PRs (snapshot at handoff)

| PR | Title | State |
|---|---|---|
| [#78](https://github.com/tyhallcsu/imessage-unsent/pull/78) | chore: refresh README artwork polish and add 2026-05-04 project review notes | OPEN, CLEAN, ready to merge |
| [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74) | fix(daemon+gui): typed RecoveryFailureCategory + per-category UI hints (closes #72) | DRAFT, CI green |
| [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73) | fix(daemon): use clonefile(2) for chat.db archive snapshots (closes #71) | DRAFT, CI green |
| [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70) | fix(daemon): skip RecoveryNotifier post when notifications are not authorized — closes #65 | OPEN, CI green |
| [#69](https://github.com/tyhallcsu/imessage-unsent/pull/69) | docs: add CLAUDE.md — orientation for AI agents continuing development | OPEN, CI green |
| [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68) | feat(daemon+docs): rolling WAL snapshot buffer for slow-unsend recovery | OPEN, CI green |

### Issues created during the prior review pass

- [#75](https://github.com/tyhallcsu/imessage-unsent/issues/75) — gui: shipped `IMUMenuBar.app` has no custom icon (Info.plist missing `CFBundleIconFile`, no `AppIcon.icns` generated). Recommended-yes for v1.0; not RC-blocking.
- [#76](https://github.com/tyhallcsu/imessage-unsent/issues/76) — docs: README and recovery-vectors lack a section explaining the WAL rolling snapshot buffer.
- [#77](https://github.com/tyhallcsu/imessage-unsent/issues/77) — docs: SECURITY.md doesn't document HMAC-SHA256 webhook signing.

### Issues already covered by an open PR (do NOT duplicate)

- [#65](https://github.com/tyhallcsu/imessage-unsent/issues/65) → PR [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70)
- [#67](https://github.com/tyhallcsu/imessage-unsent/issues/67) → PR [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68)
- [#71](https://github.com/tyhallcsu/imessage-unsent/issues/71) → PR [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73)
- [#72](https://github.com/tyhallcsu/imessage-unsent/issues/72) → PR [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74)

## Outstanding Work

Confirmed unresolved at the time of handoff:

1. **App icon not bundled** — issue [#75](https://github.com/tyhallcsu/imessage-unsent/issues/75). No `.icns` is generated; `gui/Info.plist` has no `CFBundleIconFile`. Suggested fix in the issue body.
2. **WAL rolling buffer needs user docs** — issue [#76](https://github.com/tyhallcsu/imessage-unsent/issues/76). Implementation lands in PR #68; user-facing section still TODO.
3. **SECURITY.md HMAC webhook docs** — issue [#77](https://github.com/tyhallcsu/imessage-unsent/issues/77). Implementation is correct; the doc gap is the only thing missing.
4. **PR #68 carries an unrelated icon-redesign commit** (`10f0761`). Reviewers should be aware. The polished icon is also on PR #78, so once both merge there's no conflict — but if PR #78 lands first, PR #68 may need a small rebase.
5. **No release tag yet.** Pending merges of PRs #68, #70, #73, #74, plus icon work from #75, before any v1.0 cut. RC tags are fine without #75.

## Recommended Next Step

For the next AI/developer picking this up:

1. **Merge PR [#78](https://github.com/tyhallcsu/imessage-unsent/pull/78)** — small, doc-only, all CI green. Lands the session review notes and SVG polish onto `main`.
2. Then merge in this order if reviews pass: [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70) (crash fix) → [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68) (rebase if needed after #78) → [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73) → [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74). [#69](https://github.com/tyhallcsu/imessage-unsent/pull/69) is doc-only and can land any time.
3. Pick up [#75](https://github.com/tyhallcsu/imessage-unsent/issues/75) (icon bundling) — concrete fix steps are in the issue body. Add `make icon`, an `AppIcon.icns`, the `Info.plist` key, and `build-release.sh` copy step.
4. Run `make rc-smoke VERSION=v0.3.0-rc1 OUTPUT_DIR=dist` once #75 lands and visually inspect the generated `.app`.
5. If you need to run `swift test` locally: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path daemon` (and `gui`). No `sudo` required.

If anything in this file is now stale, the canonical truth is `git log --oneline -10` and `gh pr list --state open` — trust those over this snapshot.
