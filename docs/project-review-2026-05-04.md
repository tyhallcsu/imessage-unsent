# Project Review — 2026-05-04

Lightweight progress and validation pass. Read-only review of the repo state at
the date below, plus light asset polish and a record of findings. Not a
refactor.

## Snapshot

| Field | Value |
|---|---|
| Date | 2026-05-04 |
| Reviewed against | `main` @ `844929c` |
| Review branch | `chore/asset-polish-and-review-notes` |
| Reviewer | repo maintainer + AI assist |
| Default branch | `main` |
| Remote | `https://github.com/tyhallcsu/imessage-unsent.git` |

## What was checked

- Recent commit history on `main` and on the current open feature branches.
- All open and recently closed GitHub issues + open and recent PRs.
- The last ~15 GitHub Actions runs.
- README, SECURITY.md, AGENTS.md, every file under `docs/`.
- Every file under `assets/` (validity + source-of-truth references).
- The build/test/release Makefile targets and supporting scripts.
- The icon delivery path from `assets/icon.svg` to a shipped `.app` bundle.
- Daemon and GUI Swift sources for: telemetry, network calls, message-text
  logging, hardcoded paths, and read-only invariants.

## Validation commands run

| Command | Result |
|---|---|
| `git status --short` | Working tree had cosmetic SVG + README alt-text edits; moved onto this review branch. |
| `git remote -v`, `git log --oneline -15` | Remote and history match expectations. |
| `gh repo view`, `gh issue list`, `gh pr list`, `gh run list` | See "GitHub state" below. |
| `xmllint --noout assets/*.svg` | All three SVGs valid XML. |
| `grep -nE "script\|foreignObject\|http://\|https://\|data:image" assets/*.svg` | No script tags, no foreignObject, no remote refs, no embedded raster blobs. |
| `git ls-files dist/` | Empty — `dist/` is gitignored, no committed build artifacts. |
| `find scripts script -name '*.sh' -not -perm -u+x` | All shell scripts in scripts/ and script/ have the executable bit. |
| `make shellcheck` | Pass (no warnings at `--severity=warning`). |
| `swift build --package-path daemon` | Build complete. |
| `swift build --package-path gui` | Build complete. |
| `swift test --package-path daemon` | **Did not run locally** — local toolchain is `xcode-select -p` = `/Library/Developer/CommandLineTools`, which lacks the XCTest framework. Full Xcode is installed at `/Applications/Xcode.app` but switching requires sudo. CI runs these tests on macOS runners and they pass — see GitHub Actions on PRs #68/#70/#73/#74. |
| `swift test --package-path gui` | Same — see above. |
| `make rc-smoke` | **Not run.** Takes minutes and produces a release-shaped artifact tree. Recommended before tagging an RC. |

## GitHub state

### CI
Every CI run on every open PR is currently green or in-progress. Two stale
failures from 2026-05-03 (a `Release` workflow on tag `v0.1.0-rc1` and one main
push CI run) are old enough that GitHub no longer serves the logs; they are
superseded by every subsequent green run for the same branches. Not actionable.

### Open PRs
| PR | Title | State |
|---|---|---|
| [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68) | feat(daemon+docs): rolling WAL snapshot buffer for slow-unsend recovery | OPEN, MERGEABLE, CI in progress |
| [#69](https://github.com/tyhallcsu/imessage-unsent/pull/69) | docs: add CLAUDE.md — orientation for AI agents continuing development | OPEN |
| [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70) | fix(daemon): skip RecoveryNotifier post when notifications are not authorized — closes #65 | OPEN |
| [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73) | fix(daemon): use clonefile(2) for chat.db archive snapshots (closes #71) | DRAFT |
| [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74) | fix(daemon+gui): typed RecoveryFailureCategory + per-category UI hints (closes #72) | DRAFT |

### Open issues already covered by an open PR
Do not duplicate these — they are all in flight:
- [#65](https://github.com/tyhallcsu/imessage-unsent/issues/65) → PR [#70](https://github.com/tyhallcsu/imessage-unsent/pull/70)
- [#67](https://github.com/tyhallcsu/imessage-unsent/issues/67) → PR [#68](https://github.com/tyhallcsu/imessage-unsent/pull/68)
- [#71](https://github.com/tyhallcsu/imessage-unsent/issues/71) → PR [#73](https://github.com/tyhallcsu/imessage-unsent/pull/73)
- [#72](https://github.com/tyhallcsu/imessage-unsent/issues/72) → PR [#74](https://github.com/tyhallcsu/imessage-unsent/pull/74)

### Roadmap / research issues (intentional, not actionable now)
[#15](https://github.com/tyhallcsu/imessage-unsent/issues/15), [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16), [#22](https://github.com/tyhallcsu/imessage-unsent/issues/22), [#25](https://github.com/tyhallcsu/imessage-unsent/issues/25), [#26](https://github.com/tyhallcsu/imessage-unsent/issues/26).

## What's in good shape

- **Privacy posture is solid.** One intentional outbound network call
  ([daemon/Sources/IMUCore/RecoveryNotifier.swift](../daemon/Sources/IMUCore/RecoveryNotifier.swift))
  for the optional configurable webhook; HMAC-SHA256 signed; payload
  base64-encoded. Zero telemetry/analytics. No message text logged to daemon
  stdout. Read-only invariant enforced by `SQLITE_OPEN_READONLY` and tested
  in [tests/bats/60-guardrail-no-chatdb-writes.bats](../tests/bats/60-guardrail-no-chatdb-writes.bats).
- **Repo hygiene is clean.** `.gitignore` covers all the right paths. Local RC
  artifacts in `dist/` are not tracked. No hardcoded `/Users/...` paths in any
  shell script. All shell scripts have the executable bit set. No accidental
  fixture or recovery-output commits.
- **CI workflows are comprehensive.** Shellcheck, ruff, pytest, bats, swift
  daemon tests, swift gui tests, README link check — all green on every
  recent PR.
- **SVG assets are clean.** Three source SVGs (`icon.svg`, `hero.svg`,
  `recovery-flow.svg`) all valid, no scripts, no remote refs, no base64
  rasters. README references resolve.
- **Documentation depth is good.** Architecture diagrams (Mermaid),
  per-vector recovery reference, code-signing/release-process docs, legal &
  ethics statement, README is comprehensive.

## Confirmed gaps (issues filed)

1. **Shipped `IMUMenuBar.app` has no custom icon.** `gui/Info.plist` has no
   `CFBundleIconFile` / `CFBundleIconName`. No `.icns` is generated by any
   Makefile target. `scripts/build-release.sh` packages the bundle but never
   places an `AppIcon.icns` into `Contents/Resources/`. The artwork in
   `assets/icon.svg` exists but is decorative-only — the shipped menu bar app
   uses the default app icon.
   → Filed as a new issue; recommended before any v1.0 tag.

2. **WAL rolling buffer (#67) lacks a user-facing docs section.**
   Implementation exists ([daemon/Sources/IMUCore/WALSnapshotter.swift](../daemon/Sources/IMUCore/WALSnapshotter.swift)
   and wired in [daemon/Sources/imu-watcher/main.swift](../daemon/Sources/imu-watcher/main.swift))
   and ships in PR #68. README only namechecks it. Users have no way to learn
   retention defaults, store path, or how to clear the buffer.
   → Filed as a new issue.

3. **SECURITY.md doesn't document HMAC-SHA256 webhook signing.** The doc
   covers the daemon socket threat model but not the webhook delivery
   security guarantees that are actually implemented in
   [daemon/Sources/IMUCore/RecoveryNotifier.swift](../daemon/Sources/IMUCore/RecoveryNotifier.swift).
   Operators have no documented way to verify signatures.
   → Filed as a new issue.

## Outstanding risks

- **Local Swift tests can't run without sudo.** `xcode-select -s` is required
  to point at `/Applications/Xcode.app/Contents/Developer` so XCTest is
  available. CI is unaffected. Workaround documented above.
- **PR #68's branch (`feat/67-wal-history-rolling-buffer`) carries an icon
  redesign commit (`10f0761`) that is unrelated to its WAL feature.** Not a
  bug, but reviewers should be aware. The polished icon now also lives on
  the review branch; both will land in `main` once their respective PRs
  merge.
- **No release tag is publishable yet.** Pending: app icon integration (gap
  1), categorized failure messages (PR #74), archive-via-clonefile (PR #73),
  RecoveryNotifier crash fix (PR #70).

## Release readiness

- v0.1 / v0.2 RC artifacts have been built locally before (visible in
  `dist/`).
- No tag should be cut until the four open fix PRs (#68, #70, #73, #74) are
  merged and the icon gap (issue 1 above) is resolved.
- `make rc-smoke` is the right preflight before any tag.

## Recommended next steps

1. Land the three doc/icon issues (one is the bundled-icon work; the other
   two are doc additions).
2. Merge PRs #70, #73, #74, #68 once their reviews land. Once #68 merges,
   delete the now-redundant icon redesign carrier branch.
3. Run `make rc-smoke VERSION=v0.3.0-rc1 OUTPUT_DIR=dist` and visually
   inspect the produced `.app` bundle for the icon.
4. Decide whether to merge PR #69 (CLAUDE.md handoff) — it's docs-only and
   safe to land any time.

## Files changed in this review pass

- [docs/project-review-2026-05-04.md](project-review-2026-05-04.md) — this file (new).
- [README.md](../README.md) — alt-text refinements to match polished SVGs.
- [assets/icon.svg](../assets/icon.svg) — layered speech bubble + reveal design.
- [assets/hero.svg](../assets/hero.svg) — minor polish.
- [assets/recovery-flow.svg](../assets/recovery-flow.svg) — title/desc accessibility additions.
