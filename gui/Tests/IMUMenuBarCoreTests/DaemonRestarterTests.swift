import Foundation
import XCTest
@testable import IMUMenuBarCore

final class DaemonRestarterTests: XCTestCase {
  func testSuccessReturnsNewStartedAt() async {
    let pre = makeStatus(startedAt: "2026-05-03T05:00:00Z")
    let post = makeStatus(startedAt: "2026-05-03T06:00:00Z")
    let pinger = StubPinger(responses: [true])
    let statuses = StatusSequence([pre, post])

    var commandLog: [(String, [String])] = []
    let restarter = DefaultDaemonRestarter(
      serviceTarget: "gui/501/com.imu.watcher",
      pinger: pinger,
      statusFetcher: statuses.next,
      run: { exec, args in
        commandLog.append((exec, args))
        return DefaultDaemonRestarter.LaunchctlRunResult(exitCode: 0, stdout: "", stderr: "")
      },
      pollIntervalSeconds: 0,
      pollTimeoutSeconds: 5,
      now: Date.init,
      sleep: { _ in }
    )

    let outcome = await restarter.restart()

    XCTAssertEqual(outcome, .succeeded(startedAt: "2026-05-03T06:00:00Z"))
    XCTAssertEqual(commandLog.count, 1)
    XCTAssertEqual(commandLog.first?.0, "/bin/launchctl")
    XCTAssertEqual(commandLog.first?.1, ["kickstart", "-k", "gui/501/com.imu.watcher"])
  }

  func testLaunchctlFailureSurfacesStderr() async {
    let restarter = DefaultDaemonRestarter(
      pinger: StubPinger(responses: [true]),
      statusFetcher: { nil },
      run: { _, _ in
        DefaultDaemonRestarter.LaunchctlRunResult(
          exitCode: 113,
          stdout: "",
          stderr: "Could not find service \"com.imu.watcher\" in domain for gui/501\n"
        )
      },
      pollIntervalSeconds: 0,
      pollTimeoutSeconds: 5,
      sleep: { _ in }
    )

    let outcome = await restarter.restart()

    XCTAssertEqual(
      outcome,
      .launchctlFailed(
        stderr: "Could not find service \"com.imu.watcher\" in domain for gui/501",
        exitCode: 113
      )
    )
  }

  func testTimeoutWhenStartedAtNeverChanges() async {
    let pre = makeStatus(startedAt: "2026-05-03T05:00:00Z")
    let pinger = StubPinger(responses: Array(repeating: true, count: 100))
    let statuses = StatusSequence(Array(repeating: pre, count: 100))

    var clock = Date(timeIntervalSince1970: 0)
    let restarter = DefaultDaemonRestarter(
      pinger: pinger,
      statusFetcher: statuses.next,
      run: { _, _ in DefaultDaemonRestarter.LaunchctlRunResult(exitCode: 0, stdout: "", stderr: "") },
      pollIntervalSeconds: 0.1,
      pollTimeoutSeconds: 1,
      now: { clock },
      sleep: { seconds in clock = clock.addingTimeInterval(seconds) }
    )

    let outcome = await restarter.restart()

    XCTAssertEqual(outcome, .timedOut(seconds: 1))
  }

  func testTimeoutWhenPingNeverSucceeds() async {
    let pinger = StubPinger(responses: Array(repeating: false, count: 100))
    var clock = Date(timeIntervalSince1970: 0)
    let restarter = DefaultDaemonRestarter(
      pinger: pinger,
      statusFetcher: { nil },
      run: { _, _ in DefaultDaemonRestarter.LaunchctlRunResult(exitCode: 0, stdout: "", stderr: "") },
      pollIntervalSeconds: 0.1,
      pollTimeoutSeconds: 1,
      now: { clock },
      sleep: { seconds in clock = clock.addingTimeInterval(seconds) }
    )

    let outcome = await restarter.restart()

    XCTAssertEqual(outcome, .timedOut(seconds: 1))
  }

  // MARK: - Helpers

  private func makeStatus(startedAt: String) -> DaemonStatusInfo {
    DaemonStatusInfo(
      state: "watching",
      version: "0.2.0",
      startedAt: startedAt,
      uptimeSeconds: 0,
      lastWalChangeAt: nil,
      lastWalSize: 0,
      recoveryCount: 0,
      lastError: nil,
      dataDir: "/tmp",
      notificationsShow: true
    )
  }
}

private final class StubPinger: DaemonPinging {
  private var responses: [Bool]
  init(responses: [Bool]) {
    self.responses = responses
  }
  func ping() -> Bool {
    if responses.isEmpty { return false }
    return responses.removeFirst()
  }
}

private final class StatusSequence {
  private var values: [DaemonStatusInfo?]
  init(_ values: [DaemonStatusInfo?]) {
    self.values = values
  }
  func next() -> DaemonStatusInfo? {
    if values.isEmpty { return nil }
    return values.removeFirst()
  }
}
