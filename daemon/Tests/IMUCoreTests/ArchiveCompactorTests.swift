import Foundation
import XCTest
@testable import IMUCore

/// First direct coverage of the destructive compaction path (#144 / F-L7 /
/// F-M10 test-gap): the manifest must only claim "compacted" when every
/// non-preserved file was actually removed.
final class ArchiveCompactorTests: XCTestCase {
  private var workDir: URL!
  private var archiveDir: URL!

  override func setUpWithError() throws {
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-compact-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    archiveDir = workDir.appendingPathComponent("2026-04-30T120000Z-101", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "detected_at": "2026-04-30T12:00:00.000Z",
      "rowid": 101,
      "guid": "guid-101",
      "handle": "+15550001000",
      "edited_at": 0,
      "snapshot_started_at": "2026-04-30T12:00:00.000Z",
      "snapshot_finished_at": "2026-04-30T12:00:00.500Z",
      "snap_files": [String: Any](),
      "recovery": [
        "started_at": "2026-04-30T12:00:00.000Z",
        "finished_at": "2026-04-30T12:00:01.000Z",
        "exit_code": 0,
        "recovered": true,
        "error": NSNull()
      ]
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
      .write(to: archiveDir.appendingPathComponent("manifest.json"))
    let recovery: [String: Any] = [
      "schema_version": 1,
      "recovered": ["text_b64": Data("hello".utf8).base64EncodedString()],
      "error": NSNull()
    ]
    try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted])
      .write(to: archiveDir.appendingPathComponent("recovery.json"))

    // Bulky snapshot files the compactor should remove.
    try Data(repeating: 0xAB, count: 4096).write(to: archiveDir.appendingPathComponent("chat-copy.db"))
    try Data(repeating: 0xCD, count: 2048).write(to: archiveDir.appendingPathComponent("chat-copy.db-wal"))
  }

  override func tearDown() {
    if let workDir {
      try? FileManager.default.removeItem(at: workDir)
    }
    workDir = nil
    archiveDir = nil
  }

  private func manifestState() throws -> String? {
    let data = try Data(contentsOf: archiveDir.appendingPathComponent("manifest.json"))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return object?["compaction_state"] as? String
  }

  func testSuccessfulCompactionMarksCompactedAndRemovesSnapshots() throws {
    let result = try ArchiveCompactor.compact(archiveDir: archiveDir)

    XCTAssertEqual(try manifestState(), "compacted")
    XCTAssertEqual(Set(result.removedFiles), ["chat-copy.db", "chat-copy.db-wal"])
    XCTAssertEqual(result.bytesReclaimed, 6144)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("recovery.json").path))

    XCTAssertThrowsError(try ArchiveCompactor.compact(archiveDir: archiveDir)) { error in
      guard case ArchiveCompactionError.alreadyCompacted = error else {
        return XCTFail("expected alreadyCompacted, got \(error)")
      }
    }
  }

  func testFailedRemovalMarksPartialAndStaysRetryable() throws {
    let failing = RemovalRefusingFileManager()
    failing.refuseNames = ["chat-copy.db"]

    _ = try ArchiveCompactor.compact(archiveDir: archiveDir, fileManager: failing)

    XCTAssertEqual(
      try manifestState(), "partial",
      "a compaction that left bytes on disk must not claim to be compacted"
    )
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: archiveDir.appendingPathComponent("chat-copy.db").path),
      "the refused file is still on disk"
    )

    // The retry (with a healthy FileManager) must be allowed and finish the job.
    let second = try ArchiveCompactor.compact(archiveDir: archiveDir)
    XCTAssertEqual(try manifestState(), "compacted")
    XCTAssertTrue(second.removedFiles.contains("chat-copy.db"))
  }
}

/// FileManager whose removeItem(at:) refuses named files — models uchg
/// flags, ACLs, and transient FS errors on the multi-GB snapshot family.
private final class RemovalRefusingFileManager: FileManager {
  var refuseNames: Set<String> = []

  override func removeItem(at URL: URL) throws {
    if refuseNames.contains(URL.lastPathComponent) {
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
    try super.removeItem(at: URL)
  }
}
