import Foundation
import XCTest
@testable import IMUCore

final class RetractionDetectorTests: XCTestCase {
  func testStateStorePersistsLastSeenDateEdited() throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
    let store = DetectorStateStore(url: stateURL)
    try store.save(DetectorState(lastSeenDateEdited: 42))

    XCTAssertEqual(try store.load(), DetectorState(lastSeenDateEdited: 42))
  }

  func testStateStoreSavesWithPrivatePermissions() throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Nest under a fresh parent so save() is the thing that creates the dir.
    let parent = root.appendingPathComponent("imessage-unsent", isDirectory: true)
    let stateURL = parent.appendingPathComponent("state.json", isDirectory: false)
    let store = DetectorStateStore(url: stateURL)

    try store.save(DetectorState(lastSeenDateEdited: 1, processedGUIDs: ["g"]))

    func mode(_ url: URL) throws -> Int {
      let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
      return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    XCTAssertEqual(try mode(stateURL), 0o600, "state.json must be owner-only (0600)")
    XCTAssertEqual(try mode(parent), 0o700, "state dir must be owner-only (0700)")

    // A re-save (atomic replace) must reassert 0600, not inherit a laxer mode.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)
    try store.save(DetectorState(lastSeenDateEdited: 2))
    XCTAssertEqual(try mode(stateURL), 0o600, "re-save must reassert 0600")
  }

  func testStateStoreQuarantinesCorruptFileAndReturnsFreshState() throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
    // A truncated / garbage state.json — not valid JSON for DetectorState.
    try Data("{ this is not valid json".utf8).write(to: stateURL)

    var logged: [String] = []
    let store = DetectorStateStore(
      url: stateURL,
      logger: { logged.append($0) },
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    // load() must NOT throw (that would crash-loop the daemon under KeepAlive).
    let loaded = try store.load()
    XCTAssertEqual(loaded, DetectorState())

    // The corrupt file is quarantined, not left in place to fail again.
    XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    let quarantined = directory.appendingPathComponent("state.json.corrupt-1700000000", isDirectory: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
    XCTAssertTrue(logged.contains { $0.contains("quarantined") })

    // A subsequent save + load round-trips cleanly on the fresh state.
    try store.save(DetectorState(lastSeenDateEdited: 7))
    XCTAssertEqual(try store.load(), DetectorState(lastSeenDateEdited: 7))
  }

  func testDetectorInitDoesNotThrowOnCorruptState() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }
    try Data("garbage".utf8).write(to: fixture.stateURL)

    // RetractionDetector.init loads state; it must survive corruption rather
    // than propagating a throw up to the daemon's exit(1) path (issue #109).
    XCTAssertNoThrow(
      try RetractionDetector(
        chatDBURL: fixture.chatDBURL,
        stateStore: DetectorStateStore(url: fixture.stateURL)
      )
    )
  }

  func testDetectorEmitsRetractionsAndPersistsStateAfterMarkProcessed() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-1",
      handleID: 1,
      dateEdited: 1_000
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL)
    )
    let events = try detector.detect()

    XCTAssertEqual(events, [
      RetractionDetected(
        rowid: 1,
        guid: "synthetic-guid-1",
        handle: "+15550001000",
        editedAt: 1_000
      )
    ])

    try detector.markProcessed(events)
    XCTAssertEqual(try DetectorStateStore(url: fixture.stateURL).load().lastSeenDateEdited, 1_000)
    XCTAssertEqual(try detector.detect(), [])
  }

  func testDetectorPaginatesPastFiftyRowsWithoutDroppingEvents() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetractions(
      into: fixture.chatDBURL,
      rows: (1...55).map { index in
        (guid: "synthetic-guid-\(index)", handleID: Int64(1), dateEdited: Int64(index))
      }
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL)
    )
    let events = try detector.detect()

    XCTAssertEqual(events.count, 55)
    XCTAssertEqual(events.first?.editedAt, 55)
    XCTAssertEqual(events.last?.editedAt, 1)
  }

  func testDetectFiltersGUIDsAfterMarkRecovered() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-recovered",
      handleID: 1,
      dateEdited: 1_000
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL)
    )
    let firstPass = try detector.detect()
    XCTAssertEqual(firstPass.count, 1)

    try detector.markRecovered(guid: "synthetic-guid-recovered")

    XCTAssertEqual(try detector.detect(), [])
    let persisted = try DetectorStateStore(url: fixture.stateURL).load()
    XCTAssertEqual(persisted.processedGUIDs, ["synthetic-guid-recovered"])
    XCTAssertEqual(persisted.attemptCounts, [:])
  }

  func testDetectStillReturnsGUIDBelowMaxFailedAttempts() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-flaky",
      handleID: 1,
      dateEdited: 1_000
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 3
    )
    XCTAssertEqual(try detector.detect().count, 1)

    try detector.markFailed(guid: "synthetic-guid-flaky")
    XCTAssertEqual(try detector.detect().count, 1)

    try detector.markFailed(guid: "synthetic-guid-flaky")
    XCTAssertEqual(try detector.detect().count, 1)

    XCTAssertEqual(detector.currentState().attemptCounts, ["synthetic-guid-flaky": 2])
  }

  func testDetectFiltersGUIDAfterReachingMaxFailedAttempts() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-doomed",
      handleID: 1,
      dateEdited: 1_000
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 3
    )

    try detector.markFailed(guid: "synthetic-guid-doomed")
    try detector.markFailed(guid: "synthetic-guid-doomed")
    try detector.markFailed(guid: "synthetic-guid-doomed")

    XCTAssertEqual(try detector.detect(), [])
    let persisted = try DetectorStateStore(url: fixture.stateURL).load()
    XCTAssertEqual(persisted.processedGUIDs, ["synthetic-guid-doomed"])
    XCTAssertNil(persisted.attemptCounts["synthetic-guid-doomed"])
  }

  func testMarkRecoveredClearsPriorFailedAttemptCount() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-late-success",
      handleID: 1,
      dateEdited: 1_000
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 3
    )

    try detector.markFailed(guid: "synthetic-guid-late-success")
    try detector.markFailed(guid: "synthetic-guid-late-success")
    XCTAssertEqual(detector.currentState().attemptCounts["synthetic-guid-late-success"], 2)

    try detector.markRecovered(guid: "synthetic-guid-late-success")
    let persisted = try DetectorStateStore(url: fixture.stateURL).load()
    XCTAssertEqual(persisted.processedGUIDs, ["synthetic-guid-late-success"])
    XCTAssertEqual(persisted.attemptCounts, [:])
  }

  func testProcessedGUIDsCapEvictsLexicographicallySmallestEntries() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxProcessedGUIDs: 4
    )

    for guid in ["guid-005", "guid-001", "guid-003", "guid-002"] {
      try detector.markRecovered(guid: guid)
    }
    XCTAssertEqual(detector.currentState().processedGUIDs, ["guid-001", "guid-002", "guid-003", "guid-005"])

    try detector.markRecovered(guid: "guid-004")
    let afterOverflow = detector.currentState().processedGUIDs
    XCTAssertEqual(afterOverflow.count, 4)
    XCTAssertEqual(afterOverflow, ["guid-002", "guid-003", "guid-004", "guid-005"])

    let persisted = try DetectorStateStore(url: fixture.stateURL).load()
    XCTAssertEqual(persisted.processedGUIDs, afterOverflow)
  }

  func testProcessedGUIDsCapHoldsAfterManyMarkRecoveredCalls() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    let cap = 64
    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxProcessedGUIDs: cap
    )

    for index in 0..<500 {
      try detector.markRecovered(guid: String(format: "guid-%05d", index))
    }

    let processed = detector.currentState().processedGUIDs
    XCTAssertEqual(processed.count, cap)
    XCTAssertEqual(processed.first, String(format: "guid-%05d", 500 - cap))
    XCTAssertEqual(processed.last, "guid-00499")
  }

  func testAttemptCountsCapEvictsLexicographicallySmallestKeys() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 100,
      maxAttemptCounts: 3
    )

    try detector.markFailed(guid: "guid-c")
    try detector.markFailed(guid: "guid-a")
    try detector.markFailed(guid: "guid-b")
    XCTAssertEqual(detector.currentState().attemptCounts.count, 3)

    try detector.markFailed(guid: "guid-d")
    let counts = detector.currentState().attemptCounts
    XCTAssertEqual(counts.count, 3)
    XCTAssertNil(counts["guid-a"])
    XCTAssertEqual(counts["guid-b"], 1)
    XCTAssertEqual(counts["guid-c"], 1)
    XCTAssertEqual(counts["guid-d"], 1)
  }

  func testStateStoreLoadsLegacyJSONWithoutNewFields() throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)
    let legacy = #"{"last_seen_date_edited": 7777}"#
    try legacy.write(to: stateURL, atomically: true, encoding: .utf8)

    let loaded = try DetectorStateStore(url: stateURL).load()
    XCTAssertEqual(loaded.lastSeenDateEdited, 7777)
    XCTAssertEqual(loaded.processedGUIDs, [])
    XCTAssertEqual(loaded.attemptCounts, [:])
  }

  func testWatcherToDetectorLatencyIsUnderFiveHundredMilliseconds() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL)
    )
    let callbackFired = expectation(description: "detector fires after WAL write")
    let lock = NSLock()
    var detectedEvents: [RetractionDetected] = []
    var latencyMS = 0.0
    var startedAt = Date()
    let watcher = FSWatcher(walURL: fixture.walURL, coalesceInterval: 0.05) { _ in
      do {
        let events = try detector.detect()
        guard !events.isEmpty else {
          return
        }
        try detector.markProcessed(events)
        lock.withLock {
          detectedEvents = events
          latencyMS = Date().timeIntervalSince(startedAt) * 1000
        }
        callbackFired.fulfill()
      } catch {
        XCTFail("detector callback failed: \(error)")
      }
    }

    try watcher.start()
    defer {
      watcher.stop()
    }

    startedAt = Date()
    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-latency",
      handleID: 1,
      dateEdited: appleEpochNanoseconds()
    )

    wait(for: [callbackFired], timeout: 2)
    lock.withLock {
      XCTAssertEqual(detectedEvents.first?.guid, "synthetic-guid-latency")
      XCTAssertLessThan(latencyMS, 500)
    }
  }

  private struct DetectorFixture {
    let directory: URL
    let chatDBURL: URL
    let walURL: URL
    let stateURL: URL
  }

  // MARK: - Retry semantics (#142 / F-M4)

  func testFailedEventIsRedetectedAfterMarkProcessed() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetraction(
      into: fixture.chatDBURL,
      guid: "synthetic-guid-retry",
      handleID: 1,
      dateEdited: 1_000
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 3
    )

    let events = try detector.detect()
    XCTAssertEqual(events.count, 1)

    // recover.sh found nothing → markFailed below the ceiling, then the
    // daemon loop marks the batch processed. The event must stay
    // re-detectable — the old high-water advance excluded it forever.
    try detector.markFailed(guid: "synthetic-guid-retry")
    try detector.markProcessed(events)

    XCTAssertEqual(
      try detector.detect().map(\.guid),
      ["synthetic-guid-retry"],
      "an event with retry attempts left must be re-detected after markProcessed"
    )
  }

  func testMixedBatchDoesNotStarveOlderFailedEvent() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetractions(
      into: fixture.chatDBURL,
      rows: [
        (guid: "synthetic-older-failed", handleID: 1, dateEdited: 1_000),
        (guid: "synthetic-newer-recovered", handleID: 1, dateEdited: 2_000)
      ]
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 3
    )

    let events = try detector.detect()
    XCTAssertEqual(events.count, 2)

    try detector.markFailed(guid: "synthetic-older-failed")
    try detector.markRecovered(guid: "synthetic-newer-recovered")
    try detector.markProcessed(events)

    // The newer success must not drag the high-water past the older
    // failure; the success itself stays deduped via processedGUIDs.
    XCTAssertEqual(
      try detector.detect().map(\.guid),
      ["synthetic-older-failed"],
      "a newer recovered event must not starve an older event's retries"
    )
  }

  func testHighWaterAdvancesFullyWhenAllEventsTerminal() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetractions(
      into: fixture.chatDBURL,
      rows: [
        (guid: "synthetic-done-1", handleID: 1, dateEdited: 1_000),
        (guid: "synthetic-done-2", handleID: 1, dateEdited: 2_000)
      ]
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL)
    )

    let events = try detector.detect()
    try detector.markRecovered(guid: "synthetic-done-1")
    try detector.markRecovered(guid: "synthetic-done-2")
    try detector.markProcessed(events)

    XCTAssertEqual(try detector.detect(), [])
    XCTAssertEqual(
      try DetectorStateStore(url: fixture.stateURL).load().lastSeenDateEdited,
      2_000,
      "with no live retries the high-water must advance to the newest event"
    )
  }

  func testCeilingFailureIsTerminalAndDoesNotHoldTheHighWaterBack() throws {
    let fixture = try makeDetectorFixture()
    defer {
      try? FileManager.default.removeItem(at: fixture.directory)
    }

    try insertRetractions(
      into: fixture.chatDBURL,
      rows: [
        (guid: "synthetic-exhausted", handleID: 1, dateEdited: 1_000),
        (guid: "synthetic-fresh-recovered", handleID: 1, dateEdited: 2_000)
      ]
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      maxAttempts: 3
    )

    let events = try detector.detect()
    try detector.markFailed(guid: "synthetic-exhausted")
    try detector.markFailed(guid: "synthetic-exhausted")
    try detector.markFailed(guid: "synthetic-exhausted")
    try detector.markRecovered(guid: "synthetic-fresh-recovered")
    try detector.markProcessed(events)

    XCTAssertEqual(try detector.detect(), [], "exhausted + recovered are both terminal")
    XCTAssertEqual(
      try DetectorStateStore(url: fixture.stateURL).load().lastSeenDateEdited,
      2_000,
      "a ceiling failure has no live attempts and must not pin the high-water"
    )
  }

  private func makeDetectorFixture() throws -> DetectorFixture {
    let directory = try makeTemporaryDirectory()
    let chatDBURL = directory.appendingPathComponent("chat.db", isDirectory: false)
    let walURL = directory.appendingPathComponent("chat.db-wal", isDirectory: false)
    let stateURL = directory.appendingPathComponent("state.json", isDirectory: false)

    try runSQLite(
      chatDBURL,
      sql: """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT NOT NULL, service TEXT);
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        guid TEXT NOT NULL,
        handle_id INTEGER,
        date_edited INTEGER,
        is_empty INTEGER,
        is_from_me INTEGER
      );
      INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550001000', 'iMessage');
      """
    )

    return DetectorFixture(
      directory: directory,
      chatDBURL: chatDBURL,
      walURL: walURL,
      stateURL: stateURL
    )
  }

  private func insertRetraction(
    into chatDBURL: URL,
    guid: String,
    handleID: Int64,
    dateEdited: Int64
  ) throws {
    try runSQLite(
      chatDBURL,
      sql: """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      INSERT INTO message (guid, handle_id, date_edited, is_empty, is_from_me)
      VALUES ('\(guid)', \(handleID), \(dateEdited), 1, 0);
      """
    )
  }

  private func insertRetractions(
    into chatDBURL: URL,
    rows: [(guid: String, handleID: Int64, dateEdited: Int64)]
  ) throws {
    let values = rows.map { row in
      "('\(row.guid)', \(row.handleID), \(row.dateEdited), 1, 0)"
    }.joined(separator: ",\n")

    try runSQLite(
      chatDBURL,
      sql: """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      INSERT INTO message (guid, handle_id, date_edited, is_empty, is_from_me)
      VALUES \(values);
      """
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-detector-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func runSQLite(_ databaseURL: URL, sql: String) throws {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    _ = stdout.fileHandleForReading.readDataToEndOfFile()

    if process.terminationStatus != 0 {
      let data = stderr.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
      throw SQLiteTestError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func appleEpochNanoseconds(date: Date = Date()) -> Int64 {
    Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
  }
}

private enum SQLiteTestError: Error, LocalizedError {
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case let .commandFailed(message):
      return "sqlite test command failed: \(message)"
    }
  }
}
