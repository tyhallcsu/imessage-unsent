import XCTest
@testable import IMUCore

/// Issue #163 — the detector reads receipt state off the retracted row, and
/// keeps detecting retractions when those columns are absent.
///
/// The second half matters more than the first: receipt state is additive
/// metadata, retraction detection is the daemon's entire job. A hardcoded
/// SELECT naming columns a database lacks would fail every prepare and end
/// detection silently, trading the core feature for a nice-to-have.
final class ReadReceiptDetectionTests: XCTestCase {
  /// Pin the clock to the Apple epoch so the #160 first-run grace window seeds to 0.
  /// These fixtures use Apple-epoch timestamps (797_000_010_000_000_000 == 2026-04-04);
  /// with a real clock they'd fall outside the 5-minute window and never be detected.
  private let detectorTestNow: () -> Date = { Date(timeIntervalSince1970: 978_307_200) }

  func testDetectorCapturesReceiptStateFromModernSchema() throws {
    let fixture = try makeFixture(includeReceiptColumns: true)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    try insert(
      into: fixture.chatDBURL,
      guid: "read-before",
      dateEdited: 797_000_010_000_000_000,
      receipts: (isRead: 1, dateRead: 797_000_008_200_000_000, isDelivered: 1, dateDelivered: 797_000_000_000_000_000)
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      now: detectorTestNow
    )
    let events = try detector.detect()

    XCTAssertEqual(events.count, 1)
    let context = try XCTUnwrap(events.first?.readContext)
    XCTAssertEqual(context.readState, .timestamped)
    XCTAssertEqual(context.deliveredState, .timestamped)
    XCTAssertEqual(context.readBeforeRetraction, true)
    XCTAssertEqual(try XCTUnwrap(context.readToRetractSeconds), 1.8, accuracy: 0.0001)
  }

  func testDetectorReportsFlaggedOnlyWithoutInventingATime() throws {
    let fixture = try makeFixture(includeReceiptColumns: true)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    try insert(
      into: fixture.chatDBURL,
      guid: "flag-only",
      dateEdited: 797_000_010_000_000_000,
      receipts: (isRead: 1, dateRead: 0, isDelivered: 1, dateDelivered: 0)
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      now: detectorTestNow
    )
    let context = try XCTUnwrap(try detector.detect().first?.readContext)

    XCTAssertEqual(context.readState, .flaggedOnly)
    XCTAssertNil(context.readBeforeRetraction)
    XCTAssertNil(context.readToRetractSeconds)
  }

  func testDetectionStillWorksWhenReceiptColumnsAreAbsent() throws {
    let fixture = try makeFixture(includeReceiptColumns: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    try insert(
      into: fixture.chatDBURL,
      guid: "legacy-schema",
      dateEdited: 797_000_010_000_000_000,
      receipts: nil
    )

    let detector = try RetractionDetector(
      chatDBURL: fixture.chatDBURL,
      stateStore: DetectorStateStore(url: fixture.stateURL),
      now: detectorTestNow
    )
    let events = try detector.detect()

    // The retraction is still found — that is the point.
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.guid, "legacy-schema")
    // And the receipt state is absent, not fabricated as "unread".
    XCTAssertNil(events.first?.readContext)
  }

  // MARK: - Manifest compatibility

  func testManifestRoundTripsWithReceiptBlock() throws {
    let manifest = makeManifest(
      readReceipt: RetractionReadContext(
        isRead: true,
        dateRead: 797_000_008_200_000_000,
        isDelivered: true,
        dateDelivered: 797_000_000_000_000_000,
        editedAt: 797_000_010_000_000_000
      )
    )
    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(ArchiveManifest.self, from: data)
    XCTAssertEqual(decoded.readReceipt?.readBeforeRetraction, true)
    XCTAssertEqual(decoded, manifest)

    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(object["read_receipt"])
  }

  func testManifestWrittenBeforeThisFeatureStillDecodes() throws {
    // Byte-for-byte shape of an archive already on disk: no `read_receipt`.
    let legacy = """
    {
      "detected_at": "2026-05-04T00:00:00Z",
      "rowid": 200,
      "guid": "legacy-guid",
      "handle": "+15550001000",
      "edited_at": 797000010000000000,
      "snapshot_started_at": "2026-05-04T00:00:00Z",
      "snapshot_finished_at": "2026-05-04T00:00:01Z",
      "snap_files": {}
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(ArchiveManifest.self, from: legacy)
    XCTAssertEqual(decoded.rowid, 200)
    // Unknown, not "was not read".
    XCTAssertNil(decoded.readReceipt)
  }

  func testManifestOmitsReceiptBlockWhenUnknown() throws {
    let data = try JSONEncoder().encode(makeManifest(readReceipt: nil))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(object["read_receipt"])
  }

  // MARK: - Pipeline wiring

  func testArchivePipelineCarriesReceiptStateIntoTheWrittenManifest() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-receipt-pipeline-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let recoverScript = root.appendingPathComponent("recover.sh", isDirectory: false)
    try """
    #!/usr/bin/env bash
    echo '{"schema_version":1,"recovered":{"text_b64":null}}'
    """.write(to: recoverScript, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: recoverScript.path
    )

    let pipeline = ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: root.appendingPathComponent("archives", isDirectory: true),
      recoverScriptURL: recoverScript,
      retentionLimit: 100
    )

    let event = RetractionDetected(
      rowid: 412_318,
      guid: "pipeline-guid",
      handle: "+15550001000",
      editedAt: 797_000_010_000_000_000,
      readContext: RetractionReadContext(
        isRead: true,
        dateRead: 797_000_008_200_000_000,
        isDelivered: true,
        dateDelivered: 797_000_000_000_000_000,
        editedAt: 797_000_010_000_000_000
      )
    )

    let complete = try pipeline.archive(event: event)
    let manifestURL = complete.archiveDir.appendingPathComponent("manifest.json", isDirectory: false)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
    )

    let receipt = try XCTUnwrap(object["read_receipt"] as? [String: Any])
    XCTAssertEqual(receipt["read_state"] as? String, "timestamped")
    XCTAssertEqual(receipt["read_before_retraction"] as? Bool, true)
    XCTAssertEqual(try XCTUnwrap(receipt["read_to_retract_seconds"] as? Double), 1.8, accuracy: 0.0001)
  }

  // MARK: - Helpers

  private func makeManifest(readReceipt: RetractionReadContext?) -> ArchiveManifest {
    ArchiveManifest(
      detectedAt: "2026-05-04T00:00:00Z",
      rowid: 200,
      guid: "manifest-guid",
      handle: "+15550001000",
      editedAt: 797_000_010_000_000_000,
      snapshotStartedAt: "2026-05-04T00:00:00Z",
      snapshotFinishedAt: "2026-05-04T00:00:01Z",
      snapFiles: [:],
      readReceipt: readReceipt,
      recovery: nil
    )
  }

  private struct Fixture {
    let directory: URL
    let chatDBURL: URL
    let stateURL: URL
  }

  private func makeFixture(includeReceiptColumns: Bool) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-receipts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let chatDBURL = directory.appendingPathComponent("chat.db", isDirectory: false)

    let receiptColumns = includeReceiptColumns
      ? """
        ,
              is_read INTEGER,
              date_read INTEGER,
              is_delivered INTEGER,
              date_delivered INTEGER
      """
      : ""

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
        is_from_me INTEGER\(receiptColumns)
      );
      INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550001000', 'iMessage');
      """
    )

    return Fixture(
      directory: directory,
      chatDBURL: chatDBURL,
      stateURL: directory.appendingPathComponent("state.json", isDirectory: false)
    )
  }

  private func insert(
    into chatDBURL: URL,
    guid: String,
    dateEdited: Int64,
    receipts: (isRead: Int, dateRead: Int64, isDelivered: Int, dateDelivered: Int64)?
  ) throws {
    let columns: String
    let values: String
    if let receipts {
      columns = ", is_read, date_read, is_delivered, date_delivered"
      values = ", \(receipts.isRead), \(receipts.dateRead), \(receipts.isDelivered), \(receipts.dateDelivered)"
    } else {
      columns = ""
      values = ""
    }

    try runSQLite(
      chatDBURL,
      sql: """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      INSERT INTO message (guid, handle_id, date_edited, is_empty, is_from_me\(columns))
      VALUES ('\(guid)', 1, \(dateEdited), 1, 0\(values));
      """
    )
  }

  private func runSQLite(_ databaseURL: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databaseURL.path, sql]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "sqlite3 failed for: \(sql)")
  }
}
