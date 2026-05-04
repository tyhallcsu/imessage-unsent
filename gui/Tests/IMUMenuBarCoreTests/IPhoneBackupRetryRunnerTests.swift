import Foundation
import XCTest
@testable import IMUMenuBarCore

final class IPhoneBackupRetryRunnerTests: XCTestCase {
  func testRunReportsSuccessWhenScriptExitsZero() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      echo "ok"
      exit 0
      """
    )
    let runner = IPhoneBackupRetryRunner(recoverScriptURL: scriptURL, timeoutSeconds: 5)
    let result = await runner.run(archiveDir: archiveDir, handle: "+15550001234", rowid: 42)
    if case let .success(exitCode, durationMs) = result {
      XCTAssertEqual(exitCode, 0)
      XCTAssertGreaterThanOrEqual(durationMs, 0)
    } else {
      XCTFail("expected .success, got \(result)")
    }
  }

  func testRunReportsFailureWhenScriptExitsNonZero() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      echo "boom" >&2
      exit 17
      """
    )
    let runner = IPhoneBackupRetryRunner(recoverScriptURL: scriptURL, timeoutSeconds: 5)
    let result = await runner.run(archiveDir: archiveDir, handle: "+15550001234", rowid: 42)
    if case let .failure(message) = result {
      XCTAssertTrue(message.contains("boom") || message.contains("17"), "message=\(message)")
    } else {
      XCTFail("expected .failure, got \(result)")
    }
  }

  func testRunReportsFailureWhenScriptIsMissing() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("not-there.sh", isDirectory: false)
    let archiveDir = directory.appendingPathComponent("archive", isDirectory: true)
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

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
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    let argsLog = directory.appendingPathComponent("args.txt", isDirectory: false)

    let scriptURL = try writeFakeRecoverScript(
      into: directory,
      body: """
      printf '%s\\n' "$@" > "\(argsLog.path)"
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

  private func writeFakeRecoverScript(into directory: URL, body: String) throws -> URL {
    let scriptURL = directory.appendingPathComponent("fake-recover.sh", isDirectory: false)
    let contents = "#!/bin/bash\nset -euo pipefail\n\(body)\n"
    try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }
}
