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
