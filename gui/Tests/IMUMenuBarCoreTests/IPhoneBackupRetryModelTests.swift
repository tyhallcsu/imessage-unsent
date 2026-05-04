import Foundation
import XCTest
@testable import IMUMenuBarCore

@MainActor
final class IPhoneBackupRetryModelTests: XCTestCase {
  func testRetrySetsSearchingStateWhileRunnerIsInFlight() async {
    let gate = AsyncSemaphore()
    let detail = makeDetail(recovered: true, recoveredText: "from backup")
    let model = IPhoneBackupRetryModel(
      runner: SlowStubRetryRunner(
        result: .found(detail: detail, durationMs: 12),
        gate: gate
      )
    )

    let task = Task { await model.retry(archiveDir: archiveURL, handle: "+15550001234", rowid: 42) }
    await Task.yield()
    await Task.yield()

    XCTAssertEqual(model.state, .searching)
    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(model.statusMessage, "Searching iPhone backup...")

    gate.signal()
    let reloaded = await task.value

    XCTAssertEqual(reloaded, detail)
    XCTAssertEqual(model.state, .found)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.statusMessage, "Found in iPhone backup")
  }

  func testRetryNoMatchSetsNoMatchState() async {
    let detail = makeDetail(recovered: false, recoveredText: nil)
    let model = IPhoneBackupRetryModel(
      runner: StubRetryRunner(result: .noMatch(detail: detail, durationMs: 8))
    )

    let reloaded = await model.retry(archiveDir: archiveURL, handle: "+15550001234", rowid: 42)

    XCTAssertEqual(reloaded, detail)
    XCTAssertEqual(model.state, .noMatch)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.statusMessage, "No match in iPhone backup")
  }

  func testRetryFailureSetsFailedState() async {
    let model = IPhoneBackupRetryModel(
      runner: StubRetryRunner(result: .failure(message: "recover.sh exited 17"))
    )

    let reloaded = await model.retry(archiveDir: archiveURL, handle: "+15550001234", rowid: 42)

    XCTAssertNil(reloaded)
    XCTAssertEqual(model.state, .failed(reason: "recover.sh exited 17"))
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.statusMessage, "Error: recover.sh exited 17")
  }

  private var archiveURL: URL {
    URL(fileURLWithPath: "/tmp/imu-archive", isDirectory: true)
  }

  private func makeDetail(recovered: Bool, recoveredText: String?) -> RecoveryDetail {
    RecoveryDetail(
      id: "archive-1",
      handle: "+15550001234",
      rowid: 42,
      guid: "guid-42",
      detectedAt: "2026-05-05T00:00:00.000Z",
      editedAt: 1_700_000_000,
      recovered: recovered,
      recoveredText: recoveredText,
      recoveryError: recovered ? nil : "recover.sh exited 0",
      archivePath: archiveURL.path,
      snapshotFiles: ["chat.db", "chat.db-wal"],
      failureCategory: recovered ? nil : .walCheckpointed
    )
  }
}

private struct StubRetryRunner: IPhoneBackupRetryRunning {
  let result: IPhoneBackupRetryResult

  func run(
    archiveDir _: URL,
    handle _: String,
    rowid _: Int64
  ) async -> IPhoneBackupRetryResult {
    result
  }
}

private struct SlowStubRetryRunner: IPhoneBackupRetryRunning {
  let result: IPhoneBackupRetryResult
  let gate: AsyncSemaphore

  func run(
    archiveDir _: URL,
    handle _: String,
    rowid _: Int64
  ) async -> IPhoneBackupRetryResult {
    await gate.wait()
    return result
  }
}

private final class AsyncSemaphore {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var signalCount = 0
  private let lock = NSLock()

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if signalCount > 0 {
        signalCount -= 1
        lock.unlock()
        continuation.resume()
      } else {
        continuations.append(continuation)
        lock.unlock()
      }
    }
  }

  func signal() {
    lock.lock()
    if let next = continuations.first {
      continuations.removeFirst()
      lock.unlock()
      next.resume()
    } else {
      signalCount += 1
      lock.unlock()
    }
  }
}
