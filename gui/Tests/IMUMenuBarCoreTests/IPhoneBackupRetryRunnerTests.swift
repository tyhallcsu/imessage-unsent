import Foundation
import XCTest
@testable import IMUMenuBarCore

final class IPhoneBackupRetryRunnerTests: XCTestCase {
  func testDefaultRecoverScriptURLMatchesHealthCheckPathsDefaults() {
    let runner = IPhoneBackupRetryRunner()
    XCTAssertEqual(runner.recoverScriptURL, HealthCheckPaths.defaults().recoveryScript)
  }

  func testRunReportsFoundWhenScriptWritesRecoveredJSON() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try writeManifest(at: archiveDir, recovered: false, recoveryError: "recover.sh exited 1")

    let recoveredText = "found in iphone backup"
    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      cat > "\(archiveDir.path)/recovery.json" <<'JSON'
      {"schema_version":1,"recovered":{"text_b64":"\(Data(recoveredText.utf8).base64EncodedString())","source":"iphone_backup","length":\(recoveredText.count)},"error":null}
      JSON
      exit 0
      """
    )

    let runner = IPhoneBackupRetryRunner(recoverScriptURL: scriptURL, timeoutSeconds: 5)
    let result = await runner.run(archiveDir: archiveDir, handle: "+15550001234", rowid: 42)

    if case let .found(detail, durationMs) = result {
      XCTAssertTrue(detail.recovered)
      XCTAssertEqual(detail.recoveredText, recoveredText)
      XCTAssertGreaterThanOrEqual(durationMs, 0)
    } else {
      XCTFail("expected .found, got \(result)")
    }
  }

  func testRunReportsNoMatchWhenScriptWritesNoRecoveredText() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try writeManifest(at: archiveDir, recovered: false, recoveryError: "recover.sh exited 1")

    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      cat > "\(archiveDir.path)/recovery.json" <<'JSON'
      {"schema_version":1,"recovered":{"text_b64":null,"failure_category":"wal_checkpointed"},"error":null}
      JSON
      exit 0
      """
    )

    let runner = IPhoneBackupRetryRunner(recoverScriptURL: scriptURL, timeoutSeconds: 5)
    let result = await runner.run(archiveDir: archiveDir, handle: "+15550001234", rowid: 42)

    if case let .noMatch(detail, durationMs) = result {
      XCTAssertFalse(detail.recovered)
      XCTAssertEqual(detail.failureCategory, .walCheckpointed)
      XCTAssertGreaterThanOrEqual(durationMs, 0)
    } else {
      XCTFail("expected .noMatch, got \(result)")
    }
  }

  func testRunReportsFailureWhenScriptExitsNonZero() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try writeManifest(at: archiveDir, recovered: false, recoveryError: "recover.sh exited 1")

    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      echo "stdout-only failure"
      exit 17
      """
    )
    let runner = IPhoneBackupRetryRunner(recoverScriptURL: scriptURL, timeoutSeconds: 5)
    let result = await runner.run(archiveDir: archiveDir, handle: "+15550001234", rowid: 42)

    if case let .failure(message) = result {
      XCTAssertTrue(message.contains("stdout-only failure"), "message=\(message)")
    } else {
      XCTFail("expected .failure, got \(result)")
    }
  }

  func testRunReportsFailureWhenScriptIsMissing() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("not-there.sh", isDirectory: false)
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try writeManifest(at: archiveDir, recovered: false, recoveryError: "recover.sh exited 1")

    let runner = IPhoneBackupRetryRunner(recoverScriptURL: missing, timeoutSeconds: 5)
    let result = await runner.run(archiveDir: archiveDir, handle: "+15550001234", rowid: 42)

    if case let .failure(message) = result {
      XCTAssertTrue(message.contains("not found") || message.contains("not executable"), "message=\(message)")
    } else {
      XCTFail("expected .failure for missing script, got \(result)")
    }
  }

  func testRunPassesExpectedArgumentsToScript() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try writeManifest(at: archiveDir, recovered: false, recoveryError: "recover.sh exited 1")
    let argsLog = directory.appendingPathComponent("args.txt", isDirectory: false)

    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      printf '%s\\n' "$@" > "\(argsLog.path)"
      cat > "\(archiveDir.path)/recovery.json" <<'JSON'
      {"schema_version":1,"recovered":{"text_b64":null,"failure_category":"wal_checkpointed"},"error":null}
      JSON
      exit 0
      """
    )

    let runner = IPhoneBackupRetryRunner(recoverScriptURL: scriptURL, timeoutSeconds: 5)
    _ = await runner.run(archiveDir: archiveDir, handle: "+15550009999", rowid: 1234)

    let captured = try String(contentsOf: argsLog).split(separator: "\n").map(String.init)
    XCTAssertEqual(captured, [
      "--handle", "+15550009999",
      "--rowid", "1234",
      "--include-iphone-backup",
      "--json",
      "--work", archiveDir.path
    ])
  }

  // MARK: - Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-iphone-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeManifest(
    at archiveDir: URL,
    recovered: Bool,
    recoveryError: String?
  ) throws {
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "detected_at": "2026-05-05T00:00:00.000Z",
      "rowid": 42,
      "guid": "guid-42",
      "handle": "+15550001234",
      "edited_at": 1_700_000_000,
      "snap_files": [
        "chat.db": ["present": true],
        "chat.db-wal": ["present": true]
      ],
      "recovery": [
        "recovered": recovered,
        "error": recoveryError as Any? ?? NSNull()
      ]
    ]
    try JSONSerialization.data(withJSONObject: manifest)
      .write(to: archiveDir.appendingPathComponent("manifest.json", isDirectory: false))
  }

  private func writeFakeRecoverScript(into directory: URL, body: String) throws -> URL {
    let scriptURL = directory.appendingPathComponent("fake-recover.sh", isDirectory: false)
    let contents = "#!/bin/bash\nset -euo pipefail\n\(body)\n"
    try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }
}
