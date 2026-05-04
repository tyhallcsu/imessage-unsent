# CLAUDE.md — orientation for AI agents continuing development

You're (probably) Claude Code, Codex, or another agent picking up this repo mid-flight. This file is a 5-minute brief: what the project is, what to read first, the rules that have already burned us, and what's currently in flight. The full conventions are in [AGENTS.md](AGENTS.md) — read it before any commit.

## What this is

A macOS forensic-recovery tool for iMessages another user "unsent." When the sender retracts within Apple's 2-minute window, the message body is wiped from `~/Library/Messages/chat.db` — but for a window of seconds-to-minutes, the original UTF-8 text still sits in `chat.db-wal` (SQLite's write-ahead log) before being checkpointed away. This repo extracts it.

Three components, one repo:

- **`scripts/recover.sh`** — bash + Python forensic pipeline; six recovery vectors layered (snapshot → locate → msi → attributedBody → WAL byte-scan → exporter cross-check → external backups). Read-only by design.
- **`daemon/`** (Swift, IMUCore + imu-watcher) — `LaunchAgent` that watches `chat.db-wal` via FSEvents + a 1 Hz polling fallback, runs the retraction detector against `chat.db`, archives every event, and exposes a Unix-domain control socket. Built into `~/Library/Application Support/imessage-unsent/bin/imu-watcher` by `make daemon-install`.
- **`gui/`** (SwiftUI menu-bar app, IMUMenuBar + IMUMenuBarCore) — surfaces the daemon's history + status, has Settings/Health-Check/About windows, owns notification permission. Built into `iMessage Unsent.app` (Swift target: `IMUMenuBar`; bundle id: `com.imessage-unsent.app`).

`tests/` has bats (shell) + pytest (Python) + Swift XCTest. CI runs all three on every PR.

## Hard rules — read before any commit

These are restated in `AGENTS.md` with more detail. The repo's history was rewritten once already to scrub PII; don't add it back.

1. **Never commit a real legal name.** Maintainer handle is `sharmanhall`; commit identity is `tyhallcsu <tyhallcsu@users.noreply.github.com>`. **Do not inherit `~/.gitconfig`'s `user.name`.** Set per-repo:

   ```bash
   git config user.name tyhallcsu
   git config user.email tyhallcsu@users.noreply.github.com
   ```

2. **Never commit recovery output containing real message content.** `.gitignore` blocks `recovered.txt`, `report.txt`, `msi.bin`, `msi.xml`, `chat.db*`, `imessage-recovery/`, `~/Library/Application Support/imessage-unsent/archives/`. The fixture trio under `tests/fixtures/chat.db*` is the *only* exception, and it's deterministic synthetic data.

3. **Never write to `~/Library/Messages/chat.db`** outside the explicit, gated Restore path (issue #16, currently feature-flagged off). Default and only-shipped behavior is read-only against snapshot copies. The Notify-only invariant is enforced by `tests/bats/60-guardrail-no-chatdb-writes.bats`.

4. **No `--no-verify`. No `--force-push` to `main`.** PRs squash-merge only; one PR per issue is the convention. CI failure → fix the cause, don't bypass.

5. **`ethics-review-required` issues need a second human reviewer** before merge. CODEOWNERS + branch protection enforce this once configured.

## Build & test

```bash
# Static checks (CI runs these on every PR)
make shellcheck                    # scripts/*.sh + scripts/lib/*.sh
make python-check                  # ruff + py_compile on scripts/decode.py + helpers
bats tests/bats                    # ~50 tests, fast
make python-test                   # pytest tests/python/

# Swift suites — REQUIRE Xcode (not just Command Line Tools)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path daemon
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path gui

# Full release-pipeline gate (combines all of the above + signs+notarizes if secrets present)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make rc-smoke VERSION=v0.0.0-smoke

# Daemon install/uninstall (writes to ~/Library/Application Support/imessage-unsent/ and ~/Library/LaunchAgents/)
make daemon-install
make daemon-uninstall

# Headless health probe (subset of the GUI's App Doctor)
make doctor
```

`xcode-select -p` must point at `/Applications/Xcode.app/Contents/Developer`. If it's `/Library/Developer/CommandLineTools`, swift tests fail with `no such module 'XCTest'`. Pass `DEVELOPER_DIR=` to override per-command without touching the system selector.

## Common gotchas (already cost us a session)

- **macOS Sequoia retraction predicate is `date_edited != 0 AND is_empty = 1`.** The `date_retracted` column exists in the schema but is unused on Darwin 24.x. Any code filtering on `date_retracted != 0` will silently miss every retraction. Top of `README.md` calls this out.
- **TCC tracks Full Disk Access per binary.** `make daemon-install` rebuilds `imu-watcher` with a new inode/cdhash, so an existing FDA grant for the previous binary doesn't carry over. Symptom: daemon `stat`s WAL fine (path-based metadata is leniently allowed) but `open(2)` on `chat.db` fails with `authorization denied`. Fix: System Settings → Privacy & Security → Full Disk Access → toggle `imu-watcher` OFF then back ON, then `launchctl kickstart -k gui/$(id -u)/com.imu.watcher`.
- **FSEvents on `~/Library/Messages` is unreliable.** It misses many `chat.db-wal` writes. The 1 Hz polling fallback in `FSWatcher.swift` (issue #59 / PR #60) catches what FSEvents drops. Don't remove it.
- **The pre-retract WAL page can be checkpointed away before the daemon snapshots it.** Long messages and slow unsends fail more often. Issue #67 / PR #68 add a rolling snapshot buffer at `~/Library/Application Support/imessage-unsent/wal-history/` that mitigates this. The README has a "Limitations" section that's honest about what the tool cannot recover.
- **`RecoveryNotifier.notify` throws an uncaught NSException after every successful recovery.** Issue #65, currently un-fixed. `KeepAlive=true` in the LaunchAgent plist masks it (launchd respawns within ~5 s) so recoveries land on disk; the in-memory counters reset is the visible symptom.
- **Two bundle IDs, two notification grants.** The GUI and the daemon are separate processes with separate TCC entries. PR #62 wired the GUI's "Enable notifications" button. The daemon's authorization is independent and is what blows up in issue #65 — even after the GUI is granted, the daemon is unauthorized and `UNUserNotificationCenter` throws.
- **Tests use `/Users/example` and `/Users/test` as synthetic stand-ins.** Do not replace with real paths in tests, even your own — those strings are checked in `tests/bats/`.

## Where to look

```
AGENTS.md                                  # canonical conventions / hard rules
README.md                                  # project intro + Limitations section
SECURITY.md                                # threat model + Notify-only invariant
docs/architecture.md                       # high-level component diagrams
docs/recovery-vectors.md                   # per-vector deep-dive + failure modes
docs/legal-and-ethics.md                   # CFAA / ECPA / Apple ToS / GDPR posture
docs/release-process.md                    # how to cut a release
docs/code-signing.md                       # Apple Developer ID pipeline
scripts/recover.sh                         # entry point for the bash pipeline
scripts/lib/                               # vector helpers (snapshot/scan/wal/decode)
scripts/lib/wal_extract.py                 # the byte-forensics core
scripts/lib/wal_merge_candidates.py        # PR #68 — merges live + history WAL hits
daemon/Sources/IMUCore/FSWatcher.swift     # FSEvents + polling watch (PR #60)
daemon/Sources/IMUCore/WALSnapshotter.swift # rolling buffer (PR #68 — pending)
daemon/Sources/IMUCore/RetractionDetector.swift # SQL probe + state store
daemon/Sources/IMUCore/ArchivePipeline.swift   # archive each event + run recover.sh
daemon/Sources/IMUCore/ControlServer.swift # ping/status/recent/delete socket
daemon/Sources/IMUCore/DaemonStatusBoard.swift # in-memory status surfaced to GUI
daemon/Sources/imu-watcher/main.swift      # WatcherDaemon entry point
gui/Sources/IMUMenuBarCore/Services/HealthChecker.swift # App Doctor checks
gui/Sources/IMUMenuBar/Views/SettingsWindow.swift       # Settings UI
.github/workflows/ci.yml                   # PR gate
.github/workflows/release.yml              # tag-driven build + draft release
```

## Currently in flight

Always `gh pr list --state open` for the live state, but at the time of writing:

| PR | What it does | Why it matters |
|---|---|---|
| #55 | chore: surface signing status in release notes | release-cosmetics |
| #56 | docs: legal & ethics statement (CFAA / ECPA / Apple ToS / GDPR) | required-before-public-release-style content |
| #63 | feat(gui): About window | minor UI |
| #64 | feat(daemon+gui): surface daemon's chat.db FDA status in App Doctor + Settings | makes the FDA-refresh-after-rebuild case visible without reading the daemon log |
| #66 | ci(release): split workflow — only build/sign/notarize on macOS | ~62% fewer billable Actions minutes per release |
| #68 | feat(daemon+docs): rolling WAL snapshot buffer for slow-unsend recovery | the difference-maker for long-message recovery; closes #67 |

Open issues to watch:
- **#65** — `RecoveryNotifier` NSException crash. Reliable repro, no PR yet. Suggested fix in the issue body: gate notify behind a `getNotificationSettings` authorization probe.
- **#16** — Restore mode (write to chat.db). Feature-flagged off; needs consent-flow UI before unflagging.
- **#26** — Roadmap (pinned). Phase ordering and milestone dependencies live here.

## Etiquette for the next agent

- Branch names: `feat/<issue>-<slug>`, `fix/<issue>-<slug>`, `docs/<issue>-<slug>`, `ci/<slug>`, `chore/<slug>`. Squash-merge only; PR body must include `Closes #N` if it closes an issue.
- Run `make rc-smoke VERSION=v0.0.0-smoke` locally before pushing — same checks CI runs, ~30 s on a warm cache.
- If you add a new daemon-side recovery vector, also update `docs/recovery-vectors.md` with its failure modes. We disclose limitations honestly; the README has a "Limitations" section and the per-vector doc has a failure-mode table.
- If you find a real legal name, work email, or other PII anywhere in the tree, **stop and surface it before committing.** History was rewritten once; we'd rather not do it twice.
- The `RecoveryNotifier` crash (#65) is the single bug that, if fixed, would most improve the daemon's observability. Good first task if you're looking for one.
