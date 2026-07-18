import Foundation

/// Concurrently drains a `FileHandle` (a `Pipe`'s read end) into a byte-capped
/// in-memory buffer.
///
/// Draining runs on Foundation's internal readability queue via
/// `readabilityHandler`, so it happens *concurrently* with the parent waiting on
/// the child. That is what prevents the classic deadlock where the child blocks
/// in `write(2)` after filling the ~64 KB kernel pipe buffer while the parent is
/// blocked in `waitUntilExit()` (F-H1). Once the cap is reached we keep reading
/// — to avoid re-introducing that same deadlock — but discard the overflow and
/// flag truncation.
final class SubprocessOutputDrain {
  private let handle: FileHandle
  private let cap: Int
  private let lock = NSLock()
  private var buffer = Data()
  private var truncated = false
  private var finished = false
  private let done = DispatchSemaphore(value: 0)

  init(handle: FileHandle, cap: Int) {
    self.handle = handle
    self.cap = max(0, cap)
  }

  /// Begin draining. Call once, after the owning process has launched.
  func start() {
    handle.readabilityHandler = { [weak self] fileHandle in
      guard let self else { return }
      let chunk = fileHandle.availableData
      if chunk.isEmpty {
        // Empty read == EOF: the child closed its write end.
        self.complete()
        return
      }
      self.accumulate(chunk)
    }
  }

  private func accumulate(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    if buffer.count >= cap {
      truncated = true
      return
    }
    let remaining = cap - buffer.count
    if chunk.count <= remaining {
      buffer.append(chunk)
    } else {
      buffer.append(chunk.prefix(remaining))
      truncated = true
    }
  }

  /// Detach the readability handler and signal completion. Idempotent.
  private func complete() {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    lock.unlock()
    handle.readabilityHandler = nil
    done.signal()
  }

  /// Stop draining before the process ever produced output (launch-failure path).
  func cancel() {
    complete()
  }

  /// Block up to `timeout` for EOF, then force-detach and return what we have.
  ///
  /// The bounded wait means a lingering grandchild holding the pipe's write end
  /// open — e.g. an orphaned `sleep` still alive after we killed a hung
  /// `recover.sh` — can't re-block the caller. We give up waiting for EOF and
  /// return the captured prefix so the caller's serial queue is always freed.
  func collect(timeout: TimeInterval) -> (data: Data, truncated: Bool) {
    if done.wait(timeout: .now() + timeout) == .timedOut {
      complete()
    }
    lock.lock()
    defer { lock.unlock() }
    return (buffer, truncated)
  }
}

/// Runs a subprocess with two guarantees the raw `Process` API does not provide:
///
/// 1. **No pipe deadlock (F-H1):** stdout and stderr are drained concurrently
///    with the wait, each bounded by `outputByteCap`.
/// 2. **Bounded runtime (F-H2):** the child is given `timeout` seconds, then
///    escalated SIGTERM → `terminationGrace` → SIGKILL, and reaped (best-effort)
///    before returning.
///
/// The runner is reusable and safe to call repeatedly on a serial queue: a hung
/// or chatty child can never leave the caller's queue blocked, so the watcher
/// stays able to process later events.
struct BoundedProcessRunner {
  enum Outcome: Equatable {
    /// The child exited on its own within the deadline, with this status code.
    case exited(code: Int32)
    /// The deadline was exceeded; the child was terminated/killed and reaped.
    case timedOut
    /// `process.run()` threw before the child started.
    case launchFailed(message: String)
  }

  struct Result {
    let outcome: Outcome
    let stdout: Data
    let stderr: Data
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
  }

  let timeout: TimeInterval
  let terminationGrace: TimeInterval
  let outputByteCap: Int

  init(
    timeout: TimeInterval = 120,
    terminationGrace: TimeInterval = 5,
    outputByteCap: Int = 4 * 1024 * 1024
  ) {
    self.timeout = timeout
    self.terminationGrace = terminationGrace
    self.outputByteCap = outputByteCap
  }

  func run(executableURL: URL, arguments: [String]) -> Result {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutDrain = SubprocessOutputDrain(handle: stdoutPipe.fileHandleForReading, cap: outputByteCap)
    let stderrDrain = SubprocessOutputDrain(handle: stderrPipe.fileHandleForReading, cap: outputByteCap)

    do {
      try process.run()
    } catch {
      stdoutDrain.cancel()
      stderrDrain.cancel()
      return Result(
        outcome: .launchFailed(message: error.localizedDescription),
        stdout: Data(),
        stderr: Data(),
        stdoutTruncated: false,
        stderrTruncated: false
      )
    }

    // Attach the drains immediately after launch and *before* waiting — this is
    // what keeps a chatty child from filling the pipe buffer and deadlocking.
    stdoutDrain.start()
    stderrDrain.start()

    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      exited.signal()
    }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      process.terminate() // SIGTERM
      if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        // Bounded final reap: even a briefly-unkillable (D-state) child can't
        // hang us — we return and the background waiter releases when it dies.
        _ = exited.wait(timeout: .now() + terminationGrace)
      }
    }

    let (outData, outTruncated) = stdoutDrain.collect(timeout: terminationGrace)
    let (errData, errTruncated) = stderrDrain.collect(timeout: terminationGrace)

    let outcome: Outcome = timedOut ? .timedOut : .exited(code: process.terminationStatus)
    return Result(
      outcome: outcome,
      stdout: outData,
      stderr: errData,
      stdoutTruncated: outTruncated,
      stderrTruncated: errTruncated
    )
  }
}
