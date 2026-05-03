import Foundation
import XCTest
@testable import IMUMenuBarCore

final class DaemonHistoryProviderTests: XCTestCase {
  func testMapsRecoveredEntryToSummary() {
    let client = StubControlClient(entries: [
      .init(
        id: "2026-04-30T120000Z-101",
        detectedAt: "2026-04-30T12:00:00.000Z",
        handle: "+15550001000",
        rowid: 101,
        recovered: true,
        text: "hello world",
        error: nil,
        archivePath: "/tmp/archive-101"
      )
    ])
    let provider = DaemonHistoryProvider(
      client: client,
      now: { Date(timeIntervalSinceReferenceDate: 800_000_000) }
    )

    let recoveries = provider.recentRecoveries(limit: 5)

    XCTAssertEqual(recoveries.count, 1)
    XCTAssertEqual(recoveries[0].title, "hello world")
    XCTAssertTrue(recoveries[0].detail.contains("+15550001000"))
    XCTAssertEqual(recoveries[0].archiveURL.path, "/tmp/archive-101")
  }

  func testFallsBackToErrorWhenTextMissing() {
    let client = StubControlClient(entries: [
      .init(
        id: "id",
        detectedAt: "2026-05-01T00:00:00.000Z",
        handle: "+15550009999",
        rowid: 1,
        recovered: false,
        text: nil,
        error: "recover.sh exited 1",
        archivePath: "/tmp/x"
      )
    ])
    let provider = DaemonHistoryProvider(client: client)

    let summary = provider.recentRecoveries(limit: 1).first
    XCTAssertEqual(summary?.title, "recover.sh exited 1")
  }

  func testFallsBackToPlaceholderWhenNeitherTextNorError() {
    let client = StubControlClient(entries: [
      .init(
        id: "id",
        detectedAt: "2026-05-01T00:00:00.000Z",
        handle: "+15550009999",
        rowid: 1,
        recovered: false,
        text: nil,
        error: nil,
        archivePath: "/tmp/x"
      )
    ])
    let provider = DaemonHistoryProvider(client: client)

    let summary = provider.recentRecoveries(limit: 1).first
    XCTAssertEqual(summary?.title, "(text not recoverable)")
  }

  func testReturnsEmptyWhenClientReturnsEmpty() {
    let provider = DaemonHistoryProvider(client: StubControlClient(entries: []))
    XCTAssertEqual(provider.recentRecoveries(limit: 5).count, 0)
  }
}

private final class StubControlClient: DaemonControlClienting {
  let entries: [ArchiveHistoryEntryDTO]

  init(entries: [ArchiveHistoryEntryDTO]) {
    self.entries = entries
  }

  func ping() -> Bool {
    true
  }

  func status() -> DaemonStatusInfo? {
    nil
  }

  func recent(limit: Int) -> [ArchiveHistoryEntryDTO] {
    Array(entries.prefix(limit))
  }

  func delete(id _: String) -> Bool {
    false
  }
}
