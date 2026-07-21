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

  // MARK: Full Disk Access + attention surfacing

  func testFullDiskAccessDeniedOnlyWhenProbeSaysUnreadable() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      statusProvider: { Self.statusInfo(chatDBReadable: false) }
    )
    model.refresh()

    XCTAssertTrue(model.fullDiskAccessDenied)
    XCTAssertTrue(model.needsAttention)
  }

  func testFullDiskAccessNotDeniedWhenProbeMissingOrHealthy() {
    let healthy = MenuBarModel(
      pinger: StubPinger(isUp: true),
      statusProvider: { Self.statusInfo(chatDBReadable: true) }
    )
    healthy.refresh()
    XCTAssertFalse(healthy.fullDiskAccessDenied)
    XCTAssertFalse(healthy.needsAttention)

    let probeless = MenuBarModel(
      pinger: StubPinger(isUp: true),
      statusProvider: { Self.statusInfo(chatDBReadable: nil) }
    )
    probeless.refresh()
    XCTAssertFalse(probeless.fullDiskAccessDenied, "absent probe data must not read as denied")
  }

  func testNeedsAttentionWhenDaemonIsDown() {
    let model = MenuBarModel(pinger: StubPinger(isUp: false))
    model.refresh()

    XCTAssertTrue(model.needsAttention)
    XCTAssertFalse(model.fullDiskAccessDenied)
  }

  // MARK: Action-error surfacing (silent-failure regression tests)

  func testFailedDeleteSurfacesLastActionError() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveDeleter: StubArchiveDeleter(succeed: false)
    )

    XCTAssertFalse(model.delete(id: "gone"))
    XCTAssertNotNil(model.lastActionError)
  }

  func testSuccessfulDeleteClearsLastActionError() {
    let failing = StubArchiveDeleter(succeed: false)
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveDeleter: failing
    )
    _ = model.delete(id: "gone")
    XCTAssertNotNil(model.lastActionError)

    let succeeding = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveDeleter: StubArchiveDeleter(succeed: true)
    )
    _ = succeeding.delete(id: "ok")
    XCTAssertNil(succeeding.lastActionError)
  }

  func testFailedCompactSurfacesDaemonErrorMessage() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveCompactor: StubArchiveCompactor(
        result: CompactResult(ok: false, errorMessage: "archive is busy")
      )
    )

    XCTAssertFalse(model.compact(id: "x").ok)
    XCTAssertEqual(model.lastActionError, "archive is busy")
  }

  func testRefreshDoesNotClearLastActionError() {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveDeleter: StubArchiveDeleter(succeed: false)
    )
    _ = model.delete(id: "gone")
    XCTAssertNotNil(model.lastActionError)

    model.refresh()
    XCTAssertNotNil(model.lastActionError, "the 2s poll must not wipe the failure before the user reads it")

    model.clearActionError()
    XCTAssertNil(model.lastActionError)
  }

  private static func statusInfo(chatDBReadable: Bool?) -> DaemonStatusInfo {
    DaemonStatusInfo(
      state: "watching",
      version: "0.5.0",
      startedAt: "2026-04-30T12:00:00Z",
      uptimeSeconds: 60,
      lastWalChangeAt: nil,
      lastWalSize: 0,
      recoveryCount: 0,
      lastError: nil,
      dataDir: "/Users/example/Library/Application Support/imessage-unsent",
      notificationsShow: true,
      chatDBReadable: chatDBReadable
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

private struct StubArchiveCompactor: ArchiveCompacting {
  let result: CompactResult

  func compactArchive(id _: String) -> CompactResult {
    result
  }
}

// MARK: - Async refresh + compactAll (#149 / G-2)

extension MenuBarModelTests {
  private func waitForMainActorCondition(
    timeout: TimeInterval = 5,
    _ condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  func testRefreshInBackgroundAppliesResultsOnTheMainActor() async {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      historyProvider: StubHistoryProvider(count: 2),
      entryProvider: StubEntryProvider(handles: ["+15550000001"])
    )

    model.refreshInBackground()

    let applied = await waitForMainActorCondition {
      model.status == .watching && model.recentEntries.count == 1
    }
    XCTAssertTrue(applied, "background refresh must land status + entries on the main actor")
    XCTAssertEqual(model.recentRecoveries.count, 2)
  }

  func testStartBeginsPollingWithoutAnyViewAttached() async {
    // G-3 regression: bootstrap comes from applicationDidFinishLaunching now,
    // so start() alone — no SwiftUI view, no .onAppear — must begin fetching.
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      entryProvider: StubEntryProvider(handles: ["+15550000001"])
    )

    model.start()

    let applied = await waitForMainActorCondition {
      model.status == .watching && model.recentEntries.count == 1
    }
    XCTAssertTrue(applied, "start() must kick an immediate background refresh")
  }

  func testRefreshInBackgroundReportsDownWhenDaemonUnreachable() async {
    let model = MenuBarModel(pinger: StubPinger(isUp: false))

    model.refreshInBackground()

    let applied = await waitForMainActorCondition { model.status == .down }
    XCTAssertTrue(applied)
  }

  func testCompactAllInBackgroundCountsAndSurfacesFailures() async {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveCompactor: StubFlakyCompactor(failingIds: ["bad-1"])
    )

    let result = await model.compactAllInBackground(ids: ["ok-1", "bad-1", "ok-2"])

    XCTAssertEqual(result.ok, 2)
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(result.bytesReclaimed, 2048)
    XCTAssertEqual(model.lastActionError, "Compact failed for 1 archive.")
  }

  func testCompactAllInBackgroundClearsErrorOnFullSuccess() async {
    let model = MenuBarModel(
      pinger: StubPinger(isUp: true),
      archiveCompactor: StubFlakyCompactor(failingIds: [])
    )

    let result = await model.compactAllInBackground(ids: ["ok-1"])

    XCTAssertEqual(result.failed, 0)
    XCTAssertNil(model.lastActionError)
  }
}

private struct StubFlakyCompactor: ArchiveCompacting {
  let failingIds: Set<String>

  func compactArchive(id: String) -> CompactResult {
    if failingIds.contains(id) {
      return CompactResult(ok: false, errorMessage: "synthetic failure")
    }
    return CompactResult(ok: true, bytesReclaimed: 1024)
  }
}
