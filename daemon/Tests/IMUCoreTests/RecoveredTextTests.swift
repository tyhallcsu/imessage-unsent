import XCTest
@testable import IMUCore

/// Issue #172 — "did we recover readable text?" had three answers in the codebase
/// and two were wrong. These pin the shared predicate and, more importantly, pin
/// the two consequences of getting it wrong: a false success report, and deleting
/// the only remaining copy of the evidence.
final class RecoveredTextTests: XCTestCase {
  private func payload(_ textB64: String?) -> Data {
    var recovered: [String: Any] = ["length": NSNull()]
    recovered["text_b64"] = textB64 ?? NSNull()
    return try! JSONSerialization.data(
      withJSONObject: ["schema_version": 1, "recovered": recovered]
    )
  }

  // MARK: - The predicate itself

  func testValidTextDecodes() {
    let data = payload(Data("hello world".utf8).base64EncodedString())
    XCTAssertEqual(RecoveredText.decode(fromRecoveryJSON: data), "hello world")
    XCTAssertTrue(RecoveredText.isPresent(inRecoveryJSON: data))
  }

  func testInvalidBase64IsNotRecoveredText() {
    // The old predicate returned true here: it is a non-empty String.
    let data = payload("!!!! not base64 !!!!")
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: data))
  }

  func testValidBase64ThatIsNotUTF8IsNotRecoveredText() {
    // 0xFF 0xFE 0xFD is well-formed Base64 and not valid UTF-8.
    let data = payload(Data([0xFF, 0xFE, 0xFD]).base64EncodedString())
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: data))
  }

  func testTextDecodingToEmptyIsNotRecoveredText() {
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: payload("")))
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: payload(Data().base64EncodedString())))
  }

  func testMissingOrMalformedPayloadIsNotRecoveredText() {
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: payload(nil)))
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: Data("{ truncated".utf8)))
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: Data()))
    XCTAssertNil(RecoveredText.decode(fromRecoveryJSON: Data(#"{"schema_version":1}"#.utf8)))
  }

  func testUnicodeSurvivesTheRoundTrip() {
    let original = "unsent: 🙈 café — 日本語"
    let data = payload(Data(original.utf8).base64EncodedString())
    XCTAssertEqual(RecoveredText.decode(fromRecoveryJSON: data), original)
  }

  // MARK: - Consequence 1: the manifest must not claim a false success

  func testPipelineDoesNotReportRecoveredForUndecodableText() throws {
    for bad in ["!!!! not base64 !!!!", Data([0xFF, 0xFE, 0xFD]).base64EncodedString(), ""] {
      let complete = try runPipeline(emitting: bad)
      XCTAssertFalse(
        complete.recovered,
        "an archive with undecodable text_b64 must not be reported as a recovery"
      )
      let manifest = try readManifest(complete.archiveDir)
      let recovery = try XCTUnwrap(manifest["recovery"] as? [String: Any])
      XCTAssertEqual(recovery["recovered"] as? Bool, false)
    }
  }

  func testPipelineStillReportsRealRecoveries() throws {
    let complete = try runPipeline(emitting: Data("real text".utf8).base64EncodedString())
    XCTAssertTrue(complete.recovered)
  }

  // MARK: - Consequence 2: the compactor must not delete the only copy

  func testCompactRefusesWhenTextIsUndecodable() throws {
    for bad in ["!!!! not base64 !!!!", Data([0xFF, 0xFE, 0xFD]).base64EncodedString()] {
      let dir = try makeArchive(recoveryJSON: payload(bad))
      defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

      XCTAssertThrowsError(try ArchiveCompactor.compact(archiveDir: dir)) { error in
        guard case ArchiveCompactionError.noRecoveredText = error else {
          return XCTFail("expected noRecoveredText, got \(error)")
        }
      }
      // The evidence survives — this is the whole point.
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("chat.db").path
      ), "chat.db must survive a refused compaction")
      XCTAssertTrue(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("chat.db-wal").path
      ))
    }
  }

  func testCompactRefusesOnANonEmptyButMeaninglessRecoveryJSON() throws {
    // The exact shape that used to pass: readable, non-empty, no text.
    let dir = try makeArchive(recoveryJSON: Data(#"{"schema_version":1}"#.utf8))
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    XCTAssertThrowsError(try ArchiveCompactor.compact(archiveDir: dir))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("chat.db").path
    ))
  }

  func testForceCompactsAFailedArchiveDeliberately() throws {
    let dir = try makeArchive(recoveryJSON: payload(nil))
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    let result = try ArchiveCompactor.compact(archiveDir: dir, force: true)
    XCTAssertGreaterThan(result.bytesReclaimed, 0)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("chat.db").path
    ), "force is the explicit reclaim-space path and does drop the bulk")
  }

  func testCompactStillWorksForARealRecovery() throws {
    let dir = try makeArchive(
      recoveryJSON: payload(Data("real text".utf8).base64EncodedString())
    )
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    XCTAssertNoThrow(try ArchiveCompactor.compact(archiveDir: dir))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("chat.db").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("recovery.json").path
    ), "the recovered text is what compaction preserves")
  }

  // MARK: - Consequence 3: History and the manifest must agree

  func testHistoryReaderAgreesWithTheManifestOnUndecodableText() throws {
    let complete = try runPipeline(emitting: "!!!! not base64 !!!!")
    let archivesDir = complete.archiveDir.deletingLastPathComponent()
    let entries = ArchiveHistoryReader(archivesDir: archivesDir).recent(limit: 10)
    let name = complete.archiveDir.lastPathComponent
    let entry = try XCTUnwrap(entries.first { $0.archivePath.hasSuffix(name) })
    XCTAssertFalse(entry.recovered, "History and the manifest must not disagree")
    XCTAssertNil(entry.text)
  }

  // MARK: - Helpers

  private func runPipeline(emitting textB64: String) throws -> RecoveryComplete {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-172-\(UUID().uuidString)", isDirectory: true)
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let script = root.appendingPathComponent("recover.sh", isDirectory: false)
    try """
    #!/usr/bin/env bash
    echo '{"schema_version":1,"recovered":{"text_b64":"\(textB64)"}}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    return try ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: root.appendingPathComponent("archives", isDirectory: true),
      recoverScriptURL: script,
      retentionLimit: 100
    ).archive(
      event: RetractionDetected(
        rowid: 200, guid: UUID().uuidString, handle: "+15550001000", editedAt: 1_000
      )
    )
  }

  /// A `live` archive with bulk worth losing, so a wrongly-permitted compaction
  /// is observable rather than a no-op.
  private func makeArchive(recoveryJSON: Data) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-172a-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("2026-08-04T000000Z-200", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "detected_at": "2026-08-04T00:00:00.000Z",
      "rowid": 200,
      "guid": "guid-200",
      "handle": "+15550001000",
      "edited_at": 1_000,
      "snapshot_started_at": "2026-08-04T00:00:00.000Z",
      "snapshot_finished_at": "2026-08-04T00:00:01.000Z",
      "snap_files": ["chat.db": ["present": true]]
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: dir.appendingPathComponent("manifest.json"))
    try recoveryJSON.write(to: dir.appendingPathComponent("recovery.json"))
    try Data(repeating: 0x41, count: 64 * 1024)
      .write(to: dir.appendingPathComponent("chat.db"))
    try Data(repeating: 0x42, count: 8 * 1024)
      .write(to: dir.appendingPathComponent("chat.db-wal"))
    return dir
  }

  private func readManifest(_ archiveDir: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: archiveDir.appendingPathComponent("manifest.json"))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
