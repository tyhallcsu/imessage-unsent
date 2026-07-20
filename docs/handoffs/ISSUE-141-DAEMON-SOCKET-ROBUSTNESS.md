# Handoff — Issue #141: daemon control-socket robustness

> **STATUS: WIP — NOT MERGE READY.**
> This branch is a cross-computer, cross-session checkpoint. The product code
> compiles and the core socket-ownership logic is proven by tests, but **one
> focused test (`testAbruptClientDisconnectsDoNotKillTheServer`) fails
> non-deterministically** and is unresolved. Do not merge, do not close #141,
> do not tag/release until the "Next steps" below are complete and both the
> focused **and** full daemon test suites pass.

## Purpose & date

- **Date:** 2026-07-20
- **Why this doc exists:** the original session that authored the #141 work hit
  its usage limit before it could review, commit, push, or open a PR. This
  checkpoint reviews that unfinished work, applies the minimum correction needed
  to leave a coherent branch, records exact validation results, and hands the
  remaining work to another computer / AI session.

## Repository & branch

| | |
|---|---|
| Repository | https://github.com/tyhallcsu/imessage-unsent |
| Working branch | `fix/141-daemon-socket-robustness` |
| Base branch | `main` |
| **Verified base SHA** | `ac672ff4d83dac8faef5f2be5193d4901c15c776` (merge-base with `origin/main`; branch was created from this and had **no commits** of its own before this checkpoint) |
| Issue | https://github.com/tyhallcsu/imessage-unsent/issues/141 |
| Draft PR | _to be appended after the PR is opened — see the final checkpoint report / PR body_ |
| Checkpoint commit SHA | _to be appended after commit — this is the branch commit titled `wip(daemon): checkpoint #141 socket robustness for handoff`_ |

> On the machine where this was authored the branch lived in a **locked git
> worktree**; that is machine-local and irrelevant to you. On any other
> computer: `git fetch origin && git checkout fix/141-daemon-socket-robustness`.

## Files changed (3)

```
 daemon/Sources/IMUCore/ControlServer.swift         |  63 ++++++++++-
 daemon/Sources/imu-watcher/main.swift              |  57 +++++++++-
 daemon/Tests/IMUCoreTests/ControlServerTests.swift | 124 +++++++++++++++++++++
 3 files changed, 238 insertions(+), 6 deletions(-)
```

No new/untracked files, no generated artifacts, no unrelated scope. Issue **#142**
(failed-recovery retry / high-water-mark) is deliberately **not** in this branch.

## Problem being addressed (issue #141)

Two daemon control-socket defects:

1. **SIGPIPE can kill the daemon.** A control-socket client (the GUI, or a
   Ctrl-C'd `nc`) that disconnects between sending a request and reading the
   response causes the daemon's `send(2)` to hit a broken pipe. Default SIGPIPE
   disposition terminates the whole daemon process.
2. **Any argv starts a second instance that silently steals the socket.** The
   old `main.swift` fell through to `daemon.run()` for *any* unrecognized
   argument (e.g. `imu-watcher --version`). A second daemon would then
   **unconditionally `unlink()`** the existing control socket and bind its own,
   silently hijacking control traffic from the healthy LaunchAgent instance,
   while the old server kept serving an orphaned inode.

## Intended design

- **Never SIGPIPE-die:** ignore SIGPIPE process-wide (`signal(SIGPIPE, SIG_IGN)`
  in `main.swift`) **and** set `SO_NOSIGPIPE` on each accepted client fd.
- **Never steal a live socket:** before reclaiming the socket path, probe it —
  if a listener answers, refuse to start (`ControlServerError.socketInUse`);
  only `unlink()` a path that is genuinely stale (no listener).
- **Never delete someone else's socket:** record the inode this server bound;
  on `stop()`, only `unlink()` the path while it still resolves to that inode.
- **Single-instance guard:** a `flock(LOCK_EX|LOCK_NB)` on `daemon.lock` in the
  data dir so a hand-run `imu-watcher` next to the LaunchAgent fails fast
  instead of racing `state.json` / the archives dir.
- **Strict argv:** `--version`, `--help`/`-h`, `--self-test` each do one thing
  and exit; unknown args exit non-zero **without** starting a daemon.

## Exact implementation already present

### `daemon/Sources/IMUCore/ControlServer.swift`
- New error case `ControlServerError.socketInUse(String)`.
- New private field `boundInode: ino_t?` (guarded by `lifecycleQueue`), set via
  `lstat` right after `bind`+`chmod`, cleared in `stop()`.
- `start()`: replaced the unconditional `unlink()` with — if the socket file
  exists, probe it via `socketHasListener(path:pathBytes:)`; if a listener
  answers, `close(fd)` and `throw .socketInUse`; otherwise `unlink()` the stale
  file and proceed to `bind`.
- `stop()`: only `unlink(socketPath)` when `lstat(path).st_ino == boundInode`.
- Accept loop: `setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, 1)` immediately
  after `accept`, before the concurrency-semaphore check and any response write.
- New static `socketHasListener(path:pathBytes:)`: opens a probe `AF_UNIX`
  socket and `connect(2)`s; returns `true` iff connect succeeds (a listener owns
  the file); `ECONNREFUSED`/`ENOENT` ⇒ stale ⇒ safe to unlink.

### `daemon/Sources/imu-watcher/main.swift`
- New `WatcherDaemonError.alreadyRunning(String)` with a helpful message.
- `run()`: `signal(SIGPIPE, SIG_IGN)` at the top; then a `flock`-based
  single-instance guard — `open(dataDir/daemon.lock, O_CREAT|O_WRONLY|O_CLOEXEC)`
  + `flock(LOCK_EX|LOCK_NB)`; fd held for process lifetime (`instanceLockFD`).
- New `usageText`; top-level `switch` on `CommandLine.arguments.dropFirst().first`:
  `nil`→`run()`, `--self-test`→`selfTest()`, `--version`→print `imuDaemonVersion`,
  `--help`/`-h`→print usage, otherwise print error to stderr and `exit(2)`.

### `daemon/Tests/IMUCoreTests/ControlServerTests.swift`
- New `extension ControlServerTests` (`MARK: - Socket robustness (#141)`) with
  four tests + helpers `rawConnect()` and `makeSockaddr(for:)`.
- **Checkpoint correction (this session):** hoisted `signal(SIGPIPE, SIG_IGN)`
  into `setUpWithError()`. Rationale below in "Known concerns / test harness".

## Independent review observations

Reviewed against #141's acceptance criteria. The product logic is sound:

- `pathBytes` is in scope before the `socketHasListener` call; the failure
  ordering `bind → chmod → lstat(record inode) → listen` cleans up the socket
  file on a `listen` failure (no stale socket left behind).
- `stop()` correctly guards on `started`, resets `boundInode = nil`, and only
  unlinks a path it still owns — verified by two passing tests.
- `SO_NOSIGPIPE` is applied to the accepted fd **before** any response write.
- The `flock` guard uses `O_CLOEXEC` and `LOCK_NB`; the lock dies with the
  process, so a crash cannot wedge it.
- Strict argv preserves the existing `--self-test` behavior (now required as the
  first argument, which is stricter but correct).
- `imuDaemonVersion` (`"0.4.0"`, `IMUCore/Version.swift`) is the single source of
  truth printed by `--version`.

Minor, non-blocking notes for the next agent (not defects):

- `socketHasListener` uses a **blocking** `connect(2)` with no timeout. For a
  Unix-domain socket this resolves locally and effectively immediately
  (`ECONNREFUSED` when stale), but a pathological live-but-wedged peer with a
  full backlog could in theory block the probe. Consider a non-blocking connect
  or an `SO_SNDTIMEO`/`SO_RCVTIMEO` if you want a hard bound.
- On the `listen`-failure path, `boundInode` is left set (the path is already
  unlinked and `started` stays false, so a subsequent `stop()` no-ops — harmless
  but slightly untidy).
- The `flock`-fail path throws without `close(instanceLockFD)`; harmless because
  the process exits immediately afterward, but tidy it if you touch that code.

## Known correctness concerns / unresolved failure

**One focused test fails, non-deterministically:
`testAbruptClientDisconnectsDoNotKillTheServer`.**

- It opens **50** rapid `connect → send({"op":"status"}) → close` cycles, then
  does one `ping` round-trip and asserts `ok == true`.
- Observed failures alternate between two symptoms across runs:
  - `ControlServerTests.swift:419` — `XCTAssertEqual(connectResult, 0) …
    Connection refused` (one of the 50 `connect`s is refused).
  - `ControlServerTests.swift:235` — `XCTUnwrap failed … "Unable to parse empty
    data."` (the follow-up `ping` gets an empty response).
- **Root cause (test harness / test determinism, not #141 product logic):** the
  `ControlServer` accepts **one client at a time** — `clientSemaphore.wait(timeout:
  .now())` is non-blocking, so when the single slot is busy the server
  **immediately `close()`s** the new connection (see `acceptPendingConnections`),
  and the listen backlog is only `listen(fd, 4)`. Fifty back-to-back connects
  overrun the backlog (⇒ `ECONNREFUSED`) and/or land the trailing `ping` while
  the slot is still draining a prior client (⇒ dropped ⇒ empty response). The
  test assumes the server is instantly available after a burst; it is not. This
  is a pre-existing single-client/backlog characteristic that #141 did **not**
  change — the new test merely exposes it.

**Product code vs. test harness — explicit verdict:**

- `testStartRefusesToStealALiveSocket` originally **crashed the whole test
  runner with signal 13 (SIGPIPE)**. That was a *test co-hosting artifact*: the
  `ControlServer` runs **in-process** during tests and legitimately `send(2)`s a
  response onto a client socket the test already closed. The **real daemon**
  survives this because `main.swift` sets `signal(SIGPIPE, SIG_IGN)`
  process-wide; the test process did not. Hoisting `signal(SIGPIPE, SIG_IGN)`
  into `setUp` (this checkpoint's only correction) makes that test **pass 5/5**,
  which **confirms the `socketInUse` refuse-to-steal logic is correct**.
  - Note for the next agent: per-fd `SO_NOSIGPIPE` on the server's accepted fd
    did **not** by itself prevent that crash in the in-process test; only the
    process-wide ignore did. In production the daemon has both, so it is safe —
    but it's worth a short look at why the per-fd option was insufficient here.
- `testAbruptClientDisconnectsDoNotKillTheServer`'s remaining failure is
  **not** SIGPIPE and **not** a #141-logic defect — it is the non-deterministic
  single-client/backlog race described above. Fixing it is a **design decision**
  (see Next steps) and was intentionally left unfinished per the checkpoint's
  scope.

## Exact commands run & results

Toolchain: `xcode-select -p` points at CommandLineTools, so an explicit
`DEVELOPER_DIR` override is required (otherwise Swift tests fail with
`no such module 'XCTest'`).

**Build — PASS:**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path daemon
# → Build complete!
```

**Focused tests — 17/18 PASS, 1 non-deterministic FAIL (ran the suite 3×):**
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path daemon --filter ControlServerTests
# → Executed 18 tests, with 1–2 failures (all in testAbruptClientDisconnectsDoNotKillTheServer)
```
Per-test (isolated), new #141 tests:
| Test | Result |
|---|---|
| `testStartReclaimsAStaleSocketFile` | PASS (stable) |
| `testStopLeavesAForeignSocketFileAlone` | PASS (stable) |
| `testStartRefusesToStealALiveSocket` | PASS (stable, 5/5 after the `setUp` SIGPIPE fix) |
| `testAbruptClientDisconnectsDoNotKillTheServer` | **FAIL (non-deterministic)** — `:419` Connection refused *or* `:235` empty data |

**Built-binary CLI checks — PASS, no persistent daemon started:**
```
.build/debug/imu-watcher --version              # → "0.4.0"                exit 0
.build/debug/imu-watcher --help                 # → usage text             exit 0
.build/debug/imu-watcher -h                      # → usage text             exit 0
.build/debug/imu-watcher --definitely-invalid    # → error + usage (stderr) exit 2
```
Verified via `pgrep -fl imu-watcher` before/after that these invocations added
**zero** processes; the only running instance is the pre-existing production
LaunchAgent. `--self-test` and the no-arg (daemon-start) path were **not** run
live, by design (see Safety boundaries).

## Untracked / excluded files

None. `daemon/.build/` is git-ignored (confirmed) and was not staged. The commit
contains only the three source/test files above plus this handoff document.

## Safety boundaries observed (and to keep observing)

- Read-only against git/GitHub during verification; **no** `git reset --hard`,
  `git clean`, or force-push.
- **Did not** run the daemon against the live Messages database
  (`~/Library/Messages/chat.db`).
- **Did not** run the no-arg `imu-watcher` (which would start a daemon), and
  **did not** run `--self-test` live.
- **Did not** touch Full Disk Access / TCC / Gatekeeper / SIP, the installed
  production daemon, or any LaunchAgent state.

## Next steps (recommended order)

1. **Decide the `testAbruptClientDisconnectsDoNotKillTheServer` fix.** Two lanes:
   - *Test-only (smaller):* make the test deterministic — tolerate/retry a
     refused `connect` and a dropped `ping` (the server is allowed to shed load),
     or pace the 50 connects, or assert "server still answers *eventually*"
     rather than "instantly." Keep the assertion that the server survives the
     burst; drop the assumption of instant availability.
   - *Product (larger, a real design decision):* raise the `listen()` backlog
     and/or let the accept loop briefly queue instead of immediately RST-ing an
     over-capacity connection. Only if the daemon should tolerate bursty clients.
   - **Do not** delete or weaken the test to go green.
2. **(Optional) Investigate** why per-fd `SO_NOSIGPIPE` didn't prevent the
   in-process SIGPIPE while the process-wide ignore did. Production is safe
   either way, but this clarifies whether the per-fd option is redundant.
3. **Re-run the full daemon suite**, not just the focused filter, and the GUI
   suite, and the static gates — the branch is only merge-ready when all pass.
4. **Update the PR** out of draft once green; keep `Relates to #141` until the
   `testAbrupt` failure is genuinely resolved, then switch to `Closes #141`.

## Commands the next computer should run

```bash
git fetch origin
git checkout fix/141-daemon-socket-robustness
git log --oneline -3   # confirm the wip checkpoint commit is present

# Focused reproduction of the open failure (run a few times — it's non-deterministic):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path daemon --filter ControlServerTests/testAbruptClientDisconnectsDoNotKillTheServer

# Full gate before considering merge:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path daemon
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  --package-path daemon
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  --package-path gui
make shellcheck && make python-check && bats tests/bats && make python-test
```

Requires Xcode (not just Command Line Tools):
`xcode-select -p` must be `/Applications/Xcode.app/Contents/Developer`, or pass
`DEVELOPER_DIR=…` per command as shown.

## Merge-readiness statement

**This branch is NOT merge-ready.** It is a truthful checkpoint: the product
code builds, the socket-ownership/SIGPIPE-refusal logic is proven by three
passing tests, and the strict-CLI behavior is verified on the built binary — but
`testAbruptClientDisconnectsDoNotKillTheServer` fails non-deterministically and
is unresolved. Do not merge, do not close #141, and do not tag/release until
that failure is fixed (without weakening the test) and both the focused **and**
full daemon/GUI/static suites pass.
