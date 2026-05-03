import Foundation
import XCTest
@testable import IMUMenuBarCore

@MainActor
final class DaemonRestartModelTests: XCTestCase {
  func testStartsIdle() {
    let model = DaemonRestartModel(restarter: StubRestarter(.succeeded(startedAt: "x")))
    XCTAssertEqual(model.state, .idle)
    XCTAssertFalse(model.isRestarting)
  }

  func testSuccessSetsSucceededState() async {
    let model = DaemonRestartModel(
      restarter: StubRestarter(.succeeded(startedAt: "2026-05-03T06:00:00Z"))
    )

    await model.restart()

    XCTAssertEqual(
      model.state,
      .succeeded(message: "Restarted (started at 2026-05-03T06:00:00Z)")
    )
    XCTAssertFalse(model.isRestarting)
  }

  func testLaunchctlFailureSurfacesStderr() async {
    let model = DaemonRestartModel(
      restarter: StubRestarter(.launchctlFailed(stderr: "Could not find service", exitCode: 113))
    )

    await model.restart()

    XCTAssertEqual(model.state, .failed(reason: "Could not find service"))
  }

  func testLaunchctlFailureFallbackWhenStderrEmpty() async {
    let model = DaemonRestartModel(
      restarter: StubRestarter(.launchctlFailed(stderr: "", exitCode: 1))
    )

    await model.restart()

    XCTAssertEqual(model.state, .failed(reason: "launchctl exit 1"))
  }

  func testTimeoutSetsFailedState() async {
    let model = DaemonRestartModel(restarter: StubRestarter(.timedOut(seconds: 8)))

    await model.restart()

    XCTAssertEqual(model.state, .failed(reason: "Daemon did not respond within 8s"))
  }
}

private struct StubRestarter: DaemonRestarting {
  let outcome: DaemonRestartOutcome
  init(_ outcome: DaemonRestartOutcome) {
    self.outcome = outcome
  }
  func restart() async -> DaemonRestartOutcome {
    outcome
  }
}
