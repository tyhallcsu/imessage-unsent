import Foundation
import XCTest
@testable import IMUCore

final class BoundedProcessRunnerTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-bpr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let scratch {
      try? FileManager.default.removeItem(at: scratch)
    }
  }

  // MARK: - F-H1: chatty child must not deadlock

  func testChattyStderrDoesNotDeadlockAndIsFullyCaptured() throws {
    // ~200 KB of stderr — well past the ~64 KB kernel pipe buffer that would
    // deadlock the old `waitUntilExit()`-before-drain code.
    let script = try makeScript(
      "chatty.sh",
      """
      #!/usr/bin/env bash
      head -c 200000 /dev/zero | tr '\\0' 'X' >&2
      printf '%s' '{"schema_version":1,"recovered":{"text_b64":"aGVsbG8="}}'
      exit 0
      """
    )
    let runner = BoundedProcessRunner(timeout: 30, terminationGrace: 2, outputByteCap: 4 * 1024 * 1024)

    let started = Date()
    let result = runner.run(executableURL: script, arguments: [])
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(result.outcome, .exited(code: 0))
    XCTAssertEqual(result.stderr.count, 200_000, "full stderr should be captured, not deadlocked")
    XCTAssertFalse(result.stderrTruncated)
    XCTAssertTrue(String(data: result.stdout, encoding: .utf8)?.contains("text_b64") == true)
    XCTAssertLessThan(elapsed, 15, "chatty child should return quickly, not hang")
  }

  // MARK: - F-H2: hung child must time out, be killed, and free the caller

  func testHangingChildTimesOutIsKilledAndRunnerStaysUsable() throws {
    let markers = scratch.appendingPathComponent("markers", isDirectory: true)
    try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    // Writes `started`, then blocks in `sleep` (a grandchild that keeps the
    // stdout/stderr write ends open even after we kill bash), then would write
    // `done` — which must never happen because we terminate it first.
    let hang = try makeScript(
      "hang.sh",
      """
      #!/usr/bin/env bash
      echo started > "$1/started"
      sleep 10
      echo done > "$1/done"
      """
    )
    let runner = BoundedProcessRunner(timeout: 1, terminationGrace: 0.5, outputByteCap: 1024)

    let started = Date()
    let result = runner.run(executableURL: hang, arguments: [markers.path])
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(result.outcome, .timedOut)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: markers.appendingPathComponent("started").path),
      "child should have started"
    )
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: markers.appendingPathComponent("done").path),
      "child must be killed before it finishes sleeping"
    )
    // Must return promptly even though the orphaned `sleep` still holds the pipe:
    // timeout(1) + SIGTERM grace(0.5) + two bounded drains(0.5 each) + slack.
    XCTAssertLessThan(elapsed, 8, "timeout path must not hang on a lingering grandchild")

    // The runner is stateless and must work again right after a timeout.
    let ok = try makeScript("ok.sh", "#!/usr/bin/env bash\nprintf ok\nexit 0\n")
    let second = runner.run(executableURL: ok, arguments: [])
    XCTAssertEqual(second.outcome, .exited(code: 0))
    XCTAssertEqual(String(data: second.stdout, encoding: .utf8), "ok")
  }

  // MARK: - normal success + non-zero exit

  func testSuccessfulRunCapturesBothStreams() throws {
    let script = try makeScript(
      "streams.sh",
      """
      #!/usr/bin/env bash
      printf '%s' 'OUT'
      printf '%s' 'ERR' >&2
      exit 0
      """
    )
    let result = BoundedProcessRunner(timeout: 10, terminationGrace: 1).run(executableURL: script, arguments: [])
    XCTAssertEqual(result.outcome, .exited(code: 0))
    XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "OUT")
    XCTAssertEqual(String(data: result.stderr, encoding: .utf8), "ERR")
    XCTAssertFalse(result.stdoutTruncated)
    XCTAssertFalse(result.stderrTruncated)
  }

  func testNonZeroExitIsReported() throws {
    let script = try makeScript(
      "fail.sh",
      """
      #!/usr/bin/env bash
      printf '%s' 'partial'
      exit 42
      """
    )
    let result = BoundedProcessRunner(timeout: 10, terminationGrace: 1).run(executableURL: script, arguments: [])
    XCTAssertEqual(result.outcome, .exited(code: 42))
    XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "partial")
  }

  // MARK: - byte cap / truncation

  func testOutputByteCapTruncatesAndFlags() throws {
    let script = try makeScript(
      "big.sh",
      """
      #!/usr/bin/env bash
      head -c 4096 /dev/zero | tr '\\0' 'Y'
      exit 0
      """
    )
    let result = BoundedProcessRunner(timeout: 10, terminationGrace: 1, outputByteCap: 1024)
      .run(executableURL: script, arguments: [])
    XCTAssertEqual(result.outcome, .exited(code: 0))
    XCTAssertEqual(result.stdout.count, 1024, "output must be capped at outputByteCap")
    XCTAssertTrue(result.stdoutTruncated)
  }

  // MARK: - clean exit while a grandchild keeps the pipe open

  func testCleanExitWithLingeringGrandchildStillReturnsPromptly() throws {
    // bash exits 0 immediately, but the backgrounded `sleep` inherits the
    // stdout/stderr pipe write ends. The old `readDataToEndOfFile()` would block
    // until the grandchild died; the bounded drain must return promptly.
    let script = try makeScript(
      "orphan.sh",
      """
      #!/usr/bin/env bash
      sleep 10 &
      printf '%s' 'CLEAN'
      exit 0
      """
    )
    let runner = BoundedProcessRunner(timeout: 10, terminationGrace: 0.3, outputByteCap: 1024)

    let started = Date()
    let result = runner.run(executableURL: script, arguments: [])
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertEqual(result.outcome, .exited(code: 0))
    XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "CLEAN")
    XCTAssertLessThan(elapsed, 4, "must not block on the orphaned grandchild holding the pipe")
  }

  // MARK: - launch failure

  func testLaunchFailureIsReported() {
    let missing = scratch.appendingPathComponent("does-not-exist.sh", isDirectory: false)
    let result = BoundedProcessRunner(timeout: 5, terminationGrace: 1).run(executableURL: missing, arguments: [])
    guard case .launchFailed = result.outcome else {
      return XCTFail("expected launchFailed, got \(result.outcome)")
    }
    XCTAssertTrue(result.stdout.isEmpty)
    XCTAssertTrue(result.stderr.isEmpty)
  }

  // MARK: - helpers

  private func makeScript(_ name: String, _ body: String) throws -> URL {
    let url = scratch.appendingPathComponent(name, isDirectory: false)
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}
