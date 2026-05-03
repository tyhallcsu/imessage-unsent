import Darwin
import Foundation
import XCTest
@testable import IMUCore

/// End-to-end test for the `imu-watcher` binary against the bats chat.db fixture.
///
/// Boots the real binary under a fake `$HOME`, waits for the control socket,
/// fires a WAL change via sqlite3 to trigger detection, and asserts the
/// daemon archived the recovery and reports it via the control socket.
final class DaemonBinaryE2ETests: XCTestCase {
  private var workDir: URL!
  private var fakeHome: URL!
  private var process: Process?
  private var captureHandle: FileHandle?
  private var capturePath: URL?

  override func setUpWithError() throws {
    // sockaddr_un.sun_path is 104 bytes on Darwin, so we stay shallow under
    // /private/tmp. The daemon itself constructs paths under $HOME, so $HOME
    // also needs to be short.
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-e2e-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    fakeHome = workDir.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent("Library/Messages", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent(".config/imessage-unsent", isDirectory: true),
      withIntermediateDirectories: true
    )

    // Disable native macOS notifications — UNUserNotificationCenter throws
    // without an app bundle, which a CLI test process doesn't have.
    let configURL = fakeHome.appendingPathComponent(".config/imessage-unsent/config.toml", isDirectory: false)
    try "[notifications]\nshow = false\n".write(to: configURL, atomically: true, encoding: .utf8)

    try buildFixture(into: fakeHome.appendingPathComponent("Library/Messages", isDirectory: true))
  }

  override func tearDown() {
    if let process, process.isRunning {
      kill(process.processIdentifier, SIGTERM)
      process.waitUntilExit()
    }
    captureHandle?.closeFile()
    captureHandle = nil
    if let workDir {
      try? FileManager.default.removeItem(at: workDir)
    }
    process = nil
    workDir = nil
    fakeHome = nil
  }

  func testDaemonExposesControlSocketAndArchivesRetractionAfterWalChange() throws {
    let binary = Self.packageRoot().appendingPathComponent(".build/debug/imu-watcher")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: binary.path),
      "imu-watcher must be built first (run: swift build --package-path daemon)"
    )

    try launchDaemon(binary: binary)

    let socketPath = fakeHome
      .appendingPathComponent("Library/Application Support/imessage-unsent/daemon.sock", isDirectory: false)
    try waitFor("daemon socket", deadline: 10) {
      FileManager.default.fileExists(atPath: socketPath.path)
    }

    // Daemon is alive — control socket answers ping with the new JSON protocol.
    let pingResponse = try sendRequest(#"{"op":"ping"}"#, to: socketPath)
    XCTAssertEqual(pingResponse["ok"] as? Bool, true, "ping should succeed: log=\n\(captureLog())")
    XCTAssertEqual(pingResponse["pong"] as? Bool, true)

    // Status reports our test version + the data dir under fakeHome.
    let statusResponse = try sendRequest(#"{"op":"status"}"#, to: socketPath)
    let status = try XCTUnwrap(statusResponse["status"] as? [String: Any])
    XCTAssertEqual(status["version"] as? String, imuDaemonVersion)
    XCTAssertEqual(
      status["data_dir"] as? String,
      fakeHome.appendingPathComponent("Library/Application Support/imessage-unsent").path
    )

    // Archives dir is empty until the daemon detects something.
    let archivesDir = fakeHome.appendingPathComponent(
      "Library/Application Support/imessage-unsent/archives",
      isDirectory: true
    )

    // Trigger a WAL change so FSWatcher fires. The fixture already contains a
    // retracted message (rowid 200) — first detect-after-start finds it. Use
    // `touch` so FSEvents fires without rewriting the WAL frames that hold the
    // pre-retraction text (any sqlite3 INSERT would close-checkpoint and lose
    // them).
    try touchWAL(at: fakeHome.appendingPathComponent("Library/Messages/chat.db-wal", isDirectory: false))

    // Poll recent until the recovery lands and the daemon has written the
    // post-recovery manifest. Using the socket as the wait condition avoids
    // racing the on-disk manifest writes (which happen twice — pre and post
    // recover.sh).
    var lastRecent: [[String: Any]] = []
    try waitFor("recent op to report a successful recovery", deadline: 30) {
      let response = (try? sendRequest(#"{"op":"recent","limit":5}"#, to: socketPath)) ?? [:]
      let recoveries = (response["recoveries"] as? [[String: Any]]) ?? []
      lastRecent = recoveries
      return recoveries.contains { ($0["recovered"] as? Bool) == true }
    }

    // Verify the archive directory is on disk too.
    let archiveDirs = (try? FileManager.default.contentsOfDirectory(atPath: archivesDir.path)) ?? []
    XCTAssertFalse(archiveDirs.isEmpty, "archives dir should have at least one subdir")

    let entry = try XCTUnwrap(lastRecent.first)
    XCTAssertEqual(entry["handle"] as? String, "+15551234567")
    XCTAssertEqual(entry["rowid"] as? Int, 200)
    XCTAssertEqual(entry["recovered"] as? Bool, true)
    XCTAssertEqual(entry["text"] as? String, "Recovered fixture message: hello WAL data!")
  }

  // MARK: - Helpers

  private func launchDaemon(binary: URL) throws {
    let process = Process()
    process.executableURL = binary
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = fakeHome.path
    process.environment = env
    // CWD = repo root so the daemon's `defaultRecoverScriptURL` finds
    // ./scripts/recover.sh on its first lookup.
    process.currentDirectoryURL = Self.repoRoot()

    let logURL = workDir.appendingPathComponent("watcher.log", isDirectory: false)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: logURL)
    process.standardOutput = handle
    process.standardError = handle
    capturePath = logURL
    captureHandle = handle

    try process.run()
    self.process = process
  }

  private func touchWAL(at walURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
    process.arguments = [walURL.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "touch \(walURL.path) failed")
  }

  private func waitFor(_ description: String, deadline: TimeInterval, _ check: () -> Bool) throws {
    let end = Date().addingTimeInterval(deadline)
    while Date() < end {
      if check() {
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTFail("timeout waiting for \(description) after \(deadline)s\nlog=\n\(captureLog())")
  }

  private func captureLog() -> String {
    guard let capturePath else {
      return "(no log)"
    }
    return (try? String(contentsOf: capturePath, encoding: .utf8)) ?? "(unreadable)"
  }

  private func sendRequest(_ request: String, to socketPath: URL) throws -> [String: Any] {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.path.utf8CString)
    XCTAssertLessThanOrEqual(pathBytes.count, MemoryLayout.size(ofValue: addr.sun_path))
    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
      let buffer = rawBuffer.bindMemory(to: CChar.self)
      for index in pathBytes.indices {
        buffer[index] = pathBytes[index]
      }
    }

    let connectResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(connectResult, 0, "connect to \(socketPath.path) failed: \(String(cString: strerror(errno)))")

    var tv = timeval(tv_sec: 5, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let payload = Data((request + "\n").utf8)
    payload.withUnsafeBytes { ptr in
      var offset = 0
      while offset < payload.count {
        let written = Darwin.send(fd, ptr.baseAddress?.advanced(by: offset), payload.count - offset, 0)
        if written <= 0 { break }
        offset += written
      }
    }
    // Half-close the write side so the server's recv loop sees EOF after the
    // newline and returns even if its buffering chunked the send.
    _ = Darwin.shutdown(fd, SHUT_WR)

    var buffer = Data()
    var byte: UInt8 = 0
    while buffer.count < 65_536 {
      let n = Darwin.recv(fd, &byte, 1, 0)
      if n <= 0 { break }
      if byte == 0x0A { break }
      buffer.append(byte)
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: buffer) as? [String: Any])
  }

  private func buildFixture(into messagesDir: URL) throws {
    let script = Self.repoRoot()
      .appendingPathComponent("tests/fixtures/build-fixture.sh", isDirectory: false)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path, messagesDir.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      XCTFail("build-fixture.sh failed with status \(process.terminationStatus):\n\(output)")
    }
  }

  private static func packageRoot() -> URL {
    // #filePath = .../daemon/Tests/IMUCoreTests/DaemonBinaryE2ETests.swift
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func repoRoot() -> URL {
    packageRoot().deletingLastPathComponent()
  }
}
