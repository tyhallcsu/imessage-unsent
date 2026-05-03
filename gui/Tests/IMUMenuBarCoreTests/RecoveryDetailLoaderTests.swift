import Foundation
import XCTest
@testable import IMUMenuBarCore

final class RecoveryDetailLoaderTests: XCTestCase {
  private var workDir: URL!

  override func setUpWithError() throws {
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-rdl-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let workDir { try? FileManager.default.removeItem(at: workDir) }
    workDir = nil
  }

  func testLoadsManifestAndRecoveryJSON() throws {
    let archive = workDir.appendingPathComponent("2026-04-30T120000Z-101", isDirectory: true)
    try writeArchive(at: archive, recoveredText: "hello world")

    let loader = FileSystemRecoveryDetailLoader()
    let detail = try loader.load(archiveDir: archive)

    XCTAssertEqual(detail.id, "2026-04-30T120000Z-101")
    XCTAssertEqual(detail.handle, "+15550001000")
    XCTAssertEqual(detail.rowid, 101)
    XCTAssertEqual(detail.guid, "guid-101")
    XCTAssertEqual(detail.detectedAt, "2026-04-30T12:00:00.000Z")
    XCTAssertEqual(detail.recovered, true)
    XCTAssertEqual(detail.recoveredText, "hello world")
    XCTAssertNil(detail.recoveryError)
    XCTAssertEqual(detail.archivePath, archive.path)
    XCTAssertTrue(detail.snapshotFiles.contains("chat.db-wal"))
  }

  func testReturnsRecoveryErrorWhenRecoveryJSONMissing() throws {
    let archive = workDir.appendingPathComponent("2026-04-30T120100Z-102", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
      "detected_at": "2026-04-30T12:01:00.000Z",
      "rowid": 102,
      "guid": "guid-102",
      "handle": "+15550009999",
      "edited_at": 0,
      "snapshot_started_at": "2026-04-30T12:01:00.000Z",
      "snapshot_finished_at": "2026-04-30T12:01:00.500Z",
      "snap_files": [String: Any](),
      "recovery": [
        "started_at": "2026-04-30T12:01:00.000Z",
        "finished_at": "2026-04-30T12:01:01.000Z",
        "exit_code": 1,
        "recovered": false,
        "error": "recover.sh exited 1"
      ]
    ]
    try JSONSerialization.data(withJSONObject: manifest)
      .write(to: archive.appendingPathComponent("manifest.json", isDirectory: false))

    let loader = FileSystemRecoveryDetailLoader()
    let detail = try loader.load(archiveDir: archive)

    XCTAssertFalse(detail.recovered)
    XCTAssertNil(detail.recoveredText)
    XCTAssertEqual(detail.recoveryError, "recover.sh exited 1")
  }

  func testThrowsWhenManifestMissing() {
    let archive = workDir.appendingPathComponent("2099-01-01T000000Z-1", isDirectory: true)
    try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let loader = FileSystemRecoveryDetailLoader()
    XCTAssertThrowsError(try loader.load(archiveDir: archive)) { error in
      guard case RecoveryDetailLoaderError.manifestMissing = error else {
        XCTFail("expected manifestMissing, got \(error)")
        return
      }
    }
  }

  // MARK: - helpers

  private func writeArchive(at archive: URL, recoveredText: String) throws {
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
      "detected_at": "2026-04-30T12:00:00.000Z",
      "rowid": 101,
      "guid": "guid-101",
      "handle": "+15550001000",
      "edited_at": 1_700_000_000,
      "snapshot_started_at": "2026-04-30T12:00:00.000Z",
      "snapshot_finished_at": "2026-04-30T12:00:00.500Z",
      "snap_files": [
        "chat.db": ["present": true, "size": 1024, "mtime": 0, "source_mtime": 0, "archive_mtime": 0],
        "chat.db-wal": ["present": true, "size": 4096, "mtime": 0, "source_mtime": 0, "archive_mtime": 0],
        "chat.db-shm": ["present": false, "size": 0, "mtime": 0, "source_mtime": 0, "archive_mtime": 0]
      ],
      "recovery": [
        "started_at": "2026-04-30T12:00:00.000Z",
        "finished_at": "2026-04-30T12:00:01.000Z",
        "exit_code": 0,
        "recovered": true,
        "error": NSNull()
      ]
    ]
    try JSONSerialization.data(withJSONObject: manifest)
      .write(to: archive.appendingPathComponent("manifest.json", isDirectory: false))

    let recovery: [String: Any] = [
      "schema_version": 1,
      "recovered": ["text_b64": Data(recoveredText.utf8).base64EncodedString()],
      "error": NSNull()
    ]
    try JSONSerialization.data(withJSONObject: recovery)
      .write(to: archive.appendingPathComponent("recovery.json", isDirectory: false))
  }
}
