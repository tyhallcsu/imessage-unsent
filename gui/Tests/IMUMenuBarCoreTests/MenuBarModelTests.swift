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

  func testFilteredEntriesMatchesByHandleSubstring() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      entryProvider: StubEntryProvider(handles: ["+15550000001", "+15550000002", "+15550000099"])
    )
    model.refresh()
    model.searchText = "0099"

    XCTAssertEqual(model.filteredEntries.map { $0.handle }, ["+15550000099"])
  }

  func testFilteredEntriesMatchesByContactName() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      entryProvider: StubEntryProvider(handles: ["+15550000001", "+15550000002"]),
      contactsResolver: StubContactsResolver(names: [
        "+15550000001": "Alice Example",
        "+15550000002": "Bob Other"
      ])
    )
    model.refresh()
    model.searchText = "alice"

    XCTAssertEqual(model.filteredEntries.map { $0.handle }, ["+15550000001"])
  }

  func testFilteredEntriesReturnsAllWhenSearchIsEmpty() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      entryProvider: StubEntryProvider(handles: ["+15550000001", "+15550000002"])
    )
    model.refresh()
    model.searchText = "   "

    XCTAssertEqual(model.filteredEntries.count, 2)
  }

  func testDeleteCallsDeleterAndRefreshesOnSuccess() {
    let entries = StubEntryProvider(handles: ["+15550000001", "+15550000002"])
    let deleter = StubArchiveDeleter(succeed: true)
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      entryProvider: entries,
      archiveDeleter: deleter
    )
    model.refresh()

    let target = model.recentEntries[0]
    let originalCount = entries.entries.count
    entries.entries.removeAll { $0.id == target.id }

    XCTAssertTrue(model.delete(id: target.id))
    XCTAssertEqual(deleter.deletedIds, [target.id])
    XCTAssertEqual(model.recentEntries.count, originalCount - 1, "delete must trigger refresh that drops the deleted entry")
  }

  func testDeleteReturnsFalseAndDoesNotRefreshWhenDaemonRejects() {
    let entries = StubEntryProvider(handles: ["+15550000001"])
    let deleter = StubArchiveDeleter(succeed: false)
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      entryProvider: entries,
      archiveDeleter: deleter
    )
    model.refresh()
    let originalCount = model.recentEntries.count

    XCTAssertFalse(model.delete(id: "anything"))
    XCTAssertEqual(model.recentEntries.count, originalCount)
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

private final class StubEntryProvider: RecoveryEntryProviding {
  var entries: [ArchiveHistoryEntryDTO]

  init(handles: [String]) {
    self.entries = handles.enumerated().map { index, handle in
      ArchiveHistoryEntryDTO(
        id: "2026-04-30T1200\(String(format: "%02d", index))Z-\(100 + index)",
        detectedAt: "2026-04-30T12:00:00.000Z",
        handle: handle,
        rowid: Int64(100 + index),
        recovered: true,
        text: "msg \(index)",
        error: nil,
        archivePath: "/tmp/archive-\(index)"
      )
    }
  }

  func recentEntries(limit: Int) -> [ArchiveHistoryEntryDTO] {
    Array(entries.prefix(limit))
  }
}

private struct StubContactsResolver: ContactsResolving {
  let names: [String: String]
  let images: [String: Data]

  init(names: [String: String] = [:], images: [String: Data] = [:]) {
    self.names = names
    self.images = images
  }

  func displayName(forHandle handle: String) -> String? {
    names[handle]
  }

  func avatarImageData(forHandle handle: String) -> Data? {
    images[handle]
  }
}

private final class StubArchiveDeleter: ArchiveDeleting {
  let succeed: Bool
  private(set) var deletedIds: [String] = []

  init(succeed: Bool) {
    self.succeed = succeed
  }

  func deleteArchive(id: String) -> Bool {
    deletedIds.append(id)
    return succeed
  }
}
