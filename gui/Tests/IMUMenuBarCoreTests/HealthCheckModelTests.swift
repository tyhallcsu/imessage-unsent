import Foundation
import XCTest
@testable import IMUMenuBarCore

@MainActor
final class HealthCheckModelTests: XCTestCase {
  func testReloadPopulatesChecksAndStampsLastRun() async {
    let stubChecks = [makeCheck(id: "daemon.binary", severity: .pass)]
    let checker = StubHealthChecker(result: stubChecks)
    let fixedNow = Date(timeIntervalSince1970: 1_788_000_000)
    let model = HealthCheckModel(
      checker: checker,
      appVersion: "0.4.2",
      now: { fixedNow }
    )

    XCTAssertNil(model.lastRunAt)
    XCTAssertTrue(model.checks.isEmpty)

    await model.reload()

    XCTAssertEqual(model.checks.map { $0.id }, ["daemon.binary"])
    XCTAssertEqual(model.lastRunAt, fixedNow)
    XCTAssertFalse(model.isLoading)
    XCTAssertEqual(checker.callCount, 1)
  }

  func testSecondReloadWhileFirstInFlight_isNoOp() async {
    let checker = SlowStubHealthChecker(result: [makeCheck(id: "daemon.binary", severity: .pass)])
    let model = HealthCheckModel(checker: checker, appVersion: "test")

    async let first: Void = model.reload()
    // Briefly yield so the first reload can mark isLoading = true and start awaiting.
    await Task.yield()
    await Task.yield()
    let secondTask = Task { await model.reload() }

    checker.release()
    await first
    await secondTask.value

    XCTAssertEqual(checker.callCount, 1, "double-click while loading must not re-run the checks")
  }

  func testDiagnosticsTextIncludesDaemonVersionWhenStatusRowReports() async {
    let checks: [HealthCheck] = [
      makeCheck(id: "daemon.running", severity: .pass),
      HealthCheck(
        id: "daemon.status",
        category: .daemon,
        order: 4,
        severity: .pass,
        title: "Daemon status",
        summary: "ok",
        detail: """
          Version: 0.4.1
          State: watching
          Uptime: 1h
          """,
        remediation: nil,
        remediationURL: nil
      )
    ]
    let model = HealthCheckModel(
      checker: StubHealthChecker(result: checks),
      appVersion: "0.4.2"
    )
    await model.reload()

    let text = model.diagnosticsText()
    XCTAssertTrue(text.contains("Daemon version: 0.4.1 (running)"),
                  "expected 'running' suffix from successful daemon.running, got: \(text)")
    XCTAssertTrue(text.contains("GUI version: 0.4.2"))
  }

  func testDiagnosticsTextHandlesUnreachableDaemon() async {
    let checks: [HealthCheck] = [
      makeCheck(id: "daemon.running", severity: .fail)
    ]
    let model = HealthCheckModel(
      checker: StubHealthChecker(result: checks),
      appVersion: "0.4.2"
    )
    await model.reload()

    let text = model.diagnosticsText()
    XCTAssertTrue(text.contains("Daemon version: not reachable"))
  }
}

private func makeCheck(
  id: String,
  severity: HealthSeverity,
  category: HealthCategory = .daemon,
  order: Int = 0
) -> HealthCheck {
  HealthCheck(
    id: id,
    category: category,
    order: order,
    severity: severity,
    title: id,
    summary: "summary",
    detail: nil,
    remediation: nil,
    remediationURL: nil
  )
}

private final class StubHealthChecker: HealthChecking {
  let result: [HealthCheck]
  private(set) var callCount = 0

  init(result: [HealthCheck]) { self.result = result }

  func runAll() async -> [HealthCheck] {
    callCount += 1
    return result
  }
}

private final class SlowStubHealthChecker: HealthChecking {
  let result: [HealthCheck]
  private(set) var callCount = 0
  private let semaphore = AsyncSemaphore()

  init(result: [HealthCheck]) { self.result = result }

  func runAll() async -> [HealthCheck] {
    callCount += 1
    await semaphore.wait()
    return result
  }

  func release() {
    semaphore.signal()
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
