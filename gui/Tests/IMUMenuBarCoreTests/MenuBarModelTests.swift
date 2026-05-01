import Foundation
import XCTest
@testable import IMUMenuBarCore

@MainActor
final class MenuBarModelTests: XCTestCase {
  func testRefreshShowsWatchingWhenDaemonSocketResponds() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      historyProvider: StubHistoryProvider(count: 6)
    )

    model.refresh()

    XCTAssertEqual(model.status, .watching)
    XCTAssertEqual(model.recentRecoveries.count, 5)
  }

  func testRefreshShowsDownWhenDaemonSocketDoesNotRespond() {
    let model = MenuBarModel(pinger: StubPinger(isUp: false))

    model.refresh()

    XCTAssertEqual(model.status, .down)
  }

  func testDefaultSocketPathUsesApplicationSupport() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      defaultDaemonSocketURL(home: home).path,
      "/Users/example/Library/Application Support/imessage-unsent/daemon.sock"
    )
  }
}

private struct StubPinger: DaemonPinging {
  let isUp: Bool

  func ping() -> Bool {
    isUp
  }
}

private struct StubHistoryProvider: RecoveryHistoryProviding {
  let count: Int

  func recentRecoveries(limit _: Int) -> [RecoverySummary] {
    (0..<count).map { index in
      RecoverySummary(
        title: "Recovery \(index)",
        detail: "detail",
        archiveURL: URL(fileURLWithPath: "/tmp/archive-\(index)", isDirectory: true)
      )
    }
  }
}
