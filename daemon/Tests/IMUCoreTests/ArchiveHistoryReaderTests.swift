import Foundation
import XCTest
@testable import IMUCore

final class ArchiveHistoryReaderTests: XCTestCase {
  func testReturnsEmptyWhenArchivesDirMissing() {
    let reader = ArchiveHistoryReader(
      archivesDir: URL(fileURLWithPath: "/tmp/imu-history-missing-\(UUID().uuidString)", isDirectory: true)
    )
    XCTAssertEqual(reader.recent(limit: 5), [])
  }

  func testReadsRecoveredEntryNewestFirstAndDecodesText() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    try writeArchive(
      in: root,
      name: "2026-04-30T120000Z-101",
      handle: "+15550001000",
      rowid: 101,
      detectedAt: "2026-04-30T12:00:00.000Z",
      recoveredText: "hello world",
      recoveryError: nil
    )
    try writeArchive(
      in: root,
      name: "2026-05-01T120000Z-102",
      handle: "+15550001001",
      rowid: 102,
      detectedAt: "2026-05-01T12:00:00.000Z",
      recoveredText: nil,
      recoveryError: "recover.sh exited 1"
    )
    // Malformed dir name — must be skipped silently.
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("not-an-archive", isDirectory: true),
      withIntermediateDirectories: true
    )

    var skipped: [String] = []
    let reader = ArchiveHistoryReader(
      archivesDir: root,
      onSkip: { name, _ in skipped.append(name) }
    )

    let entries = reader.recent(limit: 10)

    XCTAssertEqual(entries.count, 2)
    XCTAssertEqual(entries[0].id, "2026-05-01T120000Z-102")
    XCTAssertEqual(entries[0].handle, "+15550001001")
    XCTAssertFalse(entries[0].recovered)
    XCTAssertNil(entries[0].text)
    XCTAssertEqual(entries[0].error, "recover.sh exited 1")

    XCTAssertEqual(entries[1].id, "2026-04-30T120000Z-101")
    XCTAssertEqual(entries[1].rowid, 101)
    XCTAssertTrue(entries[1].recovered)
    XCTAssertEqual(entries[1].text, "hello world")
    XCTAssertNil(entries[1].error)

    XCTAssertEqual(skipped, []) // mismatched names are filtered before parse
  }

  func testRespectsLimit() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<5 {
      try writeArchive(
        in: root,
        name: String(format: "2026-04-%02dT120000Z-%d", 25 + index, index + 1),
        handle: "+155500\(index)",
        rowid: Int64(index + 1),
        detectedAt: "2026-04-25T12:00:00.000Z",
        recoveredText: "msg \(index)",
        recoveryError: nil
      )
    }

    let reader = ArchiveHistoryReader(archivesDir: root)
    XCTAssertEqual(reader.recent(limit: 2).count, 2)
    XCTAssertEqual(reader.recent(limit: 0), [])
  }

  func testSkipsArchiveMissingManifest() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let archive = root.appendingPathComponent("2026-04-30T120000Z-1", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

    var skipped: [String] = []
    let reader = ArchiveHistoryReader(
      archivesDir: root,
      onSkip: { name, _ in skipped.append(name) }
    )

    XCTAssertEqual(reader.recent(limit: 5), [])
    XCTAssertEqual(skipped, ["2026-04-30T120000Z-1"])
  }

  // MARK: - Helpers

  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeArchive(
    in archivesDir: URL,
    name: String,
    handle: String,
    rowid: Int64,
    detectedAt: String,
    recoveredText: String?,
    recoveryError: String?
  ) throws {
    let archive = archivesDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

    let recoveryStanza: [String: Any] = [
      "started_at": "2026-04-30T12:00:00.000Z",
      "finished_at": "2026-04-30T12:00:01.000Z",
      "exit_code": recoveryError == nil ? 0 : 1,
      "recovered": recoveredText != nil,
      "error": recoveryError as Any? ?? NSNull()
    ]
    let manifest: [String: Any] = [
      "detected_at": detectedAt,
      "rowid": rowid,
      "guid": "guid-\(rowid)",
      "handle": handle,
      "edited_at": 0,
      "snapshot_started_at": "2026-04-30T12:00:00.000Z",
      "snapshot_finished_at": "2026-04-30T12:00:00.500Z",
      "snap_files": [String: Any](),
      "recovery": recoveryStanza
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
      .write(to: archive.appendingPathComponent("manifest.json", isDirectory: false))

    let textValue: Any = recoveredText.map { Data($0.utf8).base64EncodedString() } ?? NSNull()
    let recovery: [String: Any] = [
      "schema_version": 1,
      "recovered": ["text_b64": textValue],
      "error": recoveryError as Any? ?? NSNull()
    ]
    try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted])
      .write(to: archive.appendingPathComponent("recovery.json", isDirectory: false))
  }
}
