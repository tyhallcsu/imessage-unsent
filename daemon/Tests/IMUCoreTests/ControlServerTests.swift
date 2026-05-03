import Darwin
import Foundation
import XCTest
@testable import IMUCore

final class ControlServerTests: XCTestCase {
  private var workDir: URL!
  private var server: ControlServer!
  private var socketPath: URL!
  private var statusBoard: DaemonStatusBoard!
  private var archivesDir: URL!

  override func setUpWithError() throws {
    // sockaddr_un.sun_path on Darwin is 104 bytes, so we stay shallow under
    // /private/tmp (the actual location /tmp symlinks to) to match what
    // FileManager-derived paths will report later.
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-ct-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

    archivesDir = workDir.appendingPathComponent("archives", isDirectory: true)
    try FileManager.default.createDirectory(at: archivesDir, withIntermediateDirectories: true)
    try writeFixtureArchive(
      in: archivesDir,
      name: "2026-04-30T120000Z-101",
      handle: "+15550001000",
      rowid: 101,
      recoveredText: "hello world"
    )

    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    statusBoard = DaemonStatusBoard(now: startedAt)
    statusBoard.recordWalChange(size: 4096, at: Date(timeIntervalSince1970: 1_800_000_500))
    statusBoard.recordRecovery()

    socketPath = workDir.appendingPathComponent("daemon.sock", isDirectory: false)
    server = ControlServer(
      socketPath: socketPath,
      statusBoard: statusBoard,
      historyReader: ArchiveHistoryReader(archivesDir: archivesDir),
      version: "test-0.1",
      dataDir: workDir,
      notificationsShow: true
    )
    try server.start()
  }

  override func tearDown() {
    server?.stop()
    if let workDir {
      try? FileManager.default.removeItem(at: workDir)
    }
    server = nil
    statusBoard = nil
    socketPath = nil
    workDir = nil
    archivesDir = nil
  }

  func testPingResponseShape() throws {
    let response = try roundTrip(#"{"op":"ping"}"#)
    XCTAssertEqual(response["ok"] as? Bool, true)
    XCTAssertEqual(response["pong"] as? Bool, true)
  }

  func testLegacyPlaintextPingStillWorks() throws {
    let response = try roundTrip("ping")
    XCTAssertEqual(response["ok"] as? Bool, true)
    XCTAssertEqual(response["pong"] as? Bool, true)
  }

  func testStatusResponseHasAllFields() throws {
    let response = try roundTrip(#"{"op":"status"}"#)
    XCTAssertEqual(response["ok"] as? Bool, true)
    let status = try XCTUnwrap(response["status"] as? [String: Any])
    XCTAssertEqual(status["state"] as? String, "watching")
    XCTAssertEqual(status["version"] as? String, "test-0.1")
    XCTAssertEqual(status["recovery_count"] as? Int, 1)
    XCTAssertEqual(status["last_wal_size"] as? Int, 4096)
    XCTAssertEqual(status["notifications_show"] as? Bool, true)
    XCTAssertEqual(status["data_dir"] as? String, workDir.path)
    XCTAssertNotNil(status["started_at"] as? String)
    XCTAssertNotNil(status["last_wal_change_at"] as? String)
    XCTAssertTrue(status["last_error"] is NSNull)
    XCTAssertGreaterThanOrEqual(status["uptime_seconds"] as? Int ?? -1, 0)
  }

  func testRecentResponseListsArchive() throws {
    let response = try roundTrip(#"{"op":"recent","limit":5}"#)
    XCTAssertEqual(response["ok"] as? Bool, true)
    let recoveries = try XCTUnwrap(response["recoveries"] as? [[String: Any]])
    XCTAssertEqual(recoveries.count, 1)
    let entry = recoveries[0]
    XCTAssertEqual(entry["id"] as? String, "2026-04-30T120000Z-101")
    XCTAssertEqual(entry["handle"] as? String, "+15550001000")
    XCTAssertEqual(entry["rowid"] as? Int, 101)
    XCTAssertEqual(entry["recovered"] as? Bool, true)
    XCTAssertEqual(entry["text"] as? String, "hello world")
    XCTAssertTrue(entry["error"] is NSNull)
    XCTAssertEqual(
      entry["archive_path"] as? String,
      archivesDir.appendingPathComponent("2026-04-30T120000Z-101", isDirectory: true).path
    )
  }

  func testRecentClampsLimitToValidRange() throws {
    let response = try roundTrip(#"{"op":"recent","limit":0}"#)
    XCTAssertEqual(response["ok"] as? Bool, true)
    let recoveries = try XCTUnwrap(response["recoveries"] as? [[String: Any]])
    // limit 0 is clamped to 1, and we have 1 archive so we get 1 result back
    XCTAssertEqual(recoveries.count, 1)
  }

  func testUnknownOpReturnsReadOnly() throws {
    let response = try roundTrip(#"{"op":"restore","rowid":1}"#)
    XCTAssertEqual(response["ok"] as? Bool, false)
    let error = try XCTUnwrap(response["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "read_only")
    XCTAssertTrue((error["message"] as? String ?? "").contains("restore"))
  }

  func testMalformedJSONReturnsBadRequest() throws {
    let response = try roundTrip("{not json")
    XCTAssertEqual(response["ok"] as? Bool, false)
    let error = try XCTUnwrap(response["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "bad_request")
  }

  func testMissingOpReturnsBadRequest() throws {
    let response = try roundTrip(#"{"limit":5}"#)
    XCTAssertEqual(response["ok"] as? Bool, false)
    let error = try XCTUnwrap(response["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "bad_request")
  }

  // MARK: - Helpers

  private func roundTrip(_ request: String) throws -> [String: Any] {
    let data = try sendRequest(request: request)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func sendRequest(request: String) throws -> Data {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0, "socket() failed")
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
    XCTAssertEqual(connectResult, 0, "connect() failed: \(String(cString: strerror(errno)))")

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let payload = Data((request + "\n").utf8)
    payload.withUnsafeBytes { ptr in
      _ = Darwin.send(fd, ptr.baseAddress, payload.count, 0)
    }

    var buffer = Data()
    var byte: UInt8 = 0
    while buffer.count < 65536 {
      let n = Darwin.recv(fd, &byte, 1, 0)
      if n <= 0 { break }
      if byte == 0x0A { break }
      buffer.append(byte)
    }
    return buffer
  }

  private func writeFixtureArchive(
    in archivesDir: URL,
    name: String,
    handle: String,
    rowid: Int64,
    recoveredText: String
  ) throws {
    let archive = archivesDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

    let manifest: [String: Any] = [
      "detected_at": "2026-04-30T12:00:00.000Z",
      "rowid": rowid,
      "guid": "guid-\(rowid)",
      "handle": handle,
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
      .write(to: archive.appendingPathComponent("manifest.json", isDirectory: false))

    let recovery: [String: Any] = [
      "schema_version": 1,
      "recovered": ["text_b64": Data(recoveredText.utf8).base64EncodedString()],
      "error": NSNull()
    ]
    try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted])
      .write(to: archive.appendingPathComponent("recovery.json", isDirectory: false))
  }
}
