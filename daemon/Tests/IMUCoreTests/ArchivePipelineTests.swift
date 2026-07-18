import Foundation
import XCTest
@testable import IMUCore

final class ArchivePipelineTests: XCTestCase {
  func testArchivePipelineCopiesFixtureAndRunsRecovery() throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try copyFixtureDBFamily(to: liveDir)

    let archivesDir = root.appendingPathComponent("archives", isDirectory: true)
    let pipeline = ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: archivesDir,
      recoverScriptURL: repoRoot().appendingPathComponent("scripts/recover.sh", isDirectory: false),
      retentionLimit: 100
    )
    let event = RetractionDetected(
      rowid: 200,
      guid: "00000000-0000-0000-0000-000000000001",
      handle: "+15551234567",
      editedAt: 797_000_030_000_000_010
    )

    let complete = try pipeline.archive(event: event, detectedAt: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertTrue(complete.recovered)
    XCTAssertTrue(FileManager.default.fileExists(atPath: complete.archiveDir.appendingPathComponent("chat.db").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: complete.archiveDir.appendingPathComponent("chat.db-wal").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: complete.archiveDir.appendingPathComponent("manifest.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: complete.archiveDir.appendingPathComponent("recovery.json").path))

    let manifest = try readJSON(complete.archiveDir.appendingPathComponent("manifest.json"))
    XCTAssertEqual(manifest["rowid"] as? Int, 200)
    XCTAssertEqual(manifest["handle"] as? String, "+15551234567")
    let snapFiles = try XCTUnwrap(manifest["snap_files"] as? [String: Any])
    let chatDB = try XCTUnwrap(snapFiles["chat.db"] as? [String: Any])
    XCTAssertEqual(chatDB["present"] as? Bool, true)
    XCTAssertNotNil(chatDB["source_mtime"])
    XCTAssertNotNil(chatDB["archive_mtime"])

    let recovery = try readJSON(complete.archiveDir.appendingPathComponent("recovery.json"))
    let recovered = try XCTUnwrap(recovery["recovered"] as? [String: Any])
    XCTAssertNotNil(recovered["text_b64"] as? String)
  }

  func testArchivePipelineKeepsArchiveWhenRecoveryFailsAndPrunesOldArchives() throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    let archivesDir = root.appendingPathComponent("archives", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archivesDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8).write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))
    try makeArchiveDirectory(named: "2026-04-30T010000Z-1", in: archivesDir)
    try makeArchiveDirectory(named: "2026-04-30T020000Z-2", in: archivesDir)
    let failingRecover = try makeExecutableScript(
      in: root,
      name: "recover-fails.sh",
      body: """
      #!/usr/bin/env bash
      echo '{"schema_version":1,"recovered":{"text_b64":null}}'
      exit 42
      """
    )
    let pipeline = ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: archivesDir,
      recoverScriptURL: failingRecover,
      retentionLimit: 2
    )

    let complete = try pipeline.archive(
      event: RetractionDetected(rowid: 3, guid: "guid-3", handle: "+15550001000", editedAt: 3),
      detectedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    XCTAssertFalse(complete.recovered)
    XCTAssertTrue(FileManager.default.fileExists(atPath: complete.archiveDir.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: complete.archiveDir.appendingPathComponent("recovery.json").path))
    let remainingArchives = try FileManager.default.contentsOfDirectory(atPath: archivesDir.path)
      .filter { !$0.hasPrefix(".") }
      .sorted()
    XCTAssertEqual(remainingArchives.count, 2)
    XCTAssertTrue(remainingArchives.contains(complete.archiveDir.lastPathComponent))
  }

  func testArchivePipelineCapturesChattyRecoveryWithoutDeadlock() throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    let archivesDir = root.appendingPathComponent("archives", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8).write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))
    // Emits ~200 KB to stderr (past the ~64 KB pipe buffer) before its JSON —
    // the exact shape that deadlocked the old drain-after-wait implementation.
    let chatty = try makeExecutableScript(
      in: root,
      name: "recover-chatty.sh",
      body: """
      #!/usr/bin/env bash
      head -c 200000 /dev/zero | tr '\\0' 'X' >&2
      echo '{"schema_version":1,"recovered":{"text_b64":"aGVsbG8="}}'
      exit 0
      """
    )
    let pipeline = ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: archivesDir,
      recoverScriptURL: chatty,
      retentionLimit: 100
    )

    let started = Date()
    let complete = try pipeline.archive(
      event: RetractionDetected(rowid: 7, guid: "guid-7", handle: "+15550007000", editedAt: 7),
      detectedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertTrue(complete.recovered)
    XCTAssertLessThan(elapsed, 20, "chatty recovery must not deadlock")
    let recovery = try readJSON(complete.archiveDir.appendingPathComponent("recovery.json"))
    let recovered = try XCTUnwrap(recovery["recovered"] as? [String: Any])
    XCTAssertEqual(recovered["text_b64"] as? String, "aGVsbG8=")
    let stderrData = try Data(contentsOf: complete.archiveDir.appendingPathComponent("recovery.stderr.txt"))
    XCTAssertEqual(stderrData.count, 200_000, "full stderr captured for diagnostics")
  }

  func testArchivePipelineTimesOutHungRecoveryAndReportsScriptError() throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    let archivesDir = root.appendingPathComponent("archives", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8).write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))
    let doneMarker = root.appendingPathComponent("recovery-done", isDirectory: false)
    let hang = try makeExecutableScript(
      in: root,
      name: "recover-hang.sh",
      body: """
      #!/usr/bin/env bash
      sleep 10
      echo done > "\(doneMarker.path)"
      """
    )
    let pipeline = ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: archivesDir,
      recoverScriptURL: hang,
      retentionLimit: 100,
      recoveryTimeout: 1,
      terminationGrace: 0.5
    )

    let started = Date()
    let complete = try pipeline.archive(
      event: RetractionDetected(rowid: 8, guid: "guid-8", handle: "+15550008000", editedAt: 8),
      detectedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertFalse(complete.recovered)
    XCTAssertLessThan(elapsed, 8, "hung recovery must be bounded, not block the watcher forever")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: doneMarker.path),
      "hung recovery must be killed before it finishes"
    )
    let manifest = try readJSON(complete.archiveDir.appendingPathComponent("manifest.json"))
    let recovery = try XCTUnwrap(manifest["recovery"] as? [String: Any])
    XCTAssertEqual(recovery["failure_category"] as? String, "script_error")
    XCTAssertEqual(recovery["recovered"] as? Bool, false)
    XCTAssertTrue(
      (recovery["error"] as? String)?.contains("timed out") == true,
      "error should explain the timeout"
    )
  }

  private func copyFixtureDBFamily(to destination: URL) throws {
    let fixtures = destination
      .deletingLastPathComponent()
      .appendingPathComponent("built-fixture", isDirectory: true)
    try runProcess(
      repoRoot()
        .appendingPathComponent("tests/fixtures", isDirectory: true)
        .appendingPathComponent("build-fixture.sh", isDirectory: false),
      arguments: [fixtures.path]
    )
    for name in ["chat.db", "chat.db-wal", "chat.db-shm"] {
      try FileManager.default.copyItem(
        at: fixtures.appendingPathComponent(name, isDirectory: false),
        to: destination.appendingPathComponent(name, isDirectory: false)
      )
    }
  }

  private func makeArchiveDirectory(named name: String, in archivesDir: URL) throws {
    try FileManager.default.createDirectory(
      at: archivesDir.appendingPathComponent(name, isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  private func makeExecutableScript(in directory: URL, name: String, body: String) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func runProcess(_ executable: URL, arguments: [String]) throws {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    _ = stdout.fileHandleForReading.readDataToEndOfFile()

    if process.terminationStatus != 0 {
      let data = stderr.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
      throw ArchivePipelineTestError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

private enum ArchivePipelineTestError: Error, LocalizedError {
  case processFailed(String)

  var errorDescription: String? {
    switch self {
    case let .processFailed(message):
      return "archive pipeline test process failed: \(message)"
    }
  }
}
