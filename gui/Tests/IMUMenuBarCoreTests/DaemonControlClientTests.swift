import Darwin
import Dispatch
import Foundation
import XCTest
@testable import IMUMenuBarCore

final class DaemonControlClientTests: XCTestCase {
  private var workDir: URL!
  private var socketURL: URL!
  private var server: FakeUnixSocketServer!

  override func setUpWithError() throws {
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-cct-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    socketURL = workDir.appendingPathComponent("daemon.sock", isDirectory: false)
  }

  override func tearDown() {
    server?.stop()
    if let workDir {
      try? FileManager.default.removeItem(at: workDir)
    }
    server = nil
    workDir = nil
    socketURL = nil
  }

  func testPingSendsRequestAndParsesPong() throws {
    server = try startFakeServer(response: #"{"ok":true,"pong":true}"#)
    let client = DaemonControlClient(socketURL: socketURL)

    XCTAssertTrue(client.ping())

    let request = server.lastRequest()
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
    XCTAssertEqual(json["op"] as? String, "ping")
  }

  func testStatusDecodesPayload() throws {
    let payload = """
    {"ok":true,"status":{"state":"watching","version":"0.2.0","started_at":"2026-04-30T12:00:00.000Z",\
    "uptime_seconds":42,"last_wal_change_at":"2026-04-30T12:00:30.000Z","last_wal_size":4096,\
    "recovery_count":3,"last_error":null,"data_dir":"/tmp/imu","notifications_show":true}}
    """
    server = try startFakeServer(response: payload)
    let client = DaemonControlClient(socketURL: socketURL)

    let info = client.status()

    XCTAssertEqual(info?.state, "watching")
    XCTAssertEqual(info?.version, "0.2.0")
    XCTAssertEqual(info?.uptimeSeconds, 42)
    XCTAssertEqual(info?.lastWalSize, 4096)
    XCTAssertEqual(info?.recoveryCount, 3)
    XCTAssertNil(info?.lastError)
    XCTAssertEqual(info?.dataDir, "/tmp/imu")
    XCTAssertEqual(info?.notificationsShow, true)
  }

  func testRecentDecodesEntries() throws {
    let payload = """
    {"ok":true,"recoveries":[{"id":"a","detected_at":"2026-04-30T12:00:00.000Z","handle":"+1",\
    "rowid":7,"recovered":true,"text":"hi","error":null,"archive_path":"/tmp/a"}]}
    """
    server = try startFakeServer(response: payload)
    let client = DaemonControlClient(socketURL: socketURL)

    let entries = client.recent(limit: 5)

    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].id, "a")
    XCTAssertEqual(entries[0].handle, "+1")
    XCTAssertEqual(entries[0].rowid, 7)
    XCTAssertEqual(entries[0].text, "hi")
    XCTAssertEqual(entries[0].archivePath, "/tmp/a")
  }

  func testReturnsFalseWhenServerNotRunning() {
    let client = DaemonControlClient(socketURL: socketURL)
    XCTAssertFalse(client.ping())
    XCTAssertNil(client.status())
    XCTAssertEqual(client.recent(limit: 5), [])
  }

  func testRecentClampsLimitInRequest() throws {
    server = try startFakeServer(response: #"{"ok":true,"recoveries":[]}"#)
    let client = DaemonControlClient(socketURL: socketURL)

    _ = client.recent(limit: 999)

    let request = server.lastRequest()
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
    XCTAssertEqual(json["limit"] as? Int, 50)
  }

  func testDeleteSendsIdAndReportsSuccess() throws {
    server = try startFakeServer(response: #"{"ok":true,"deleted":"2026-04-30T120000Z-101"}"#)
    let client = DaemonControlClient(socketURL: socketURL)

    XCTAssertTrue(client.delete(id: "2026-04-30T120000Z-101"))

    let request = server.lastRequest()
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
    XCTAssertEqual(json["op"] as? String, "delete")
    XCTAssertEqual(json["id"] as? String, "2026-04-30T120000Z-101")
  }

  func testDeleteReturnsFalseOnDaemonError() throws {
    server = try startFakeServer(response: #"{"ok":false,"error":{"code":"not_found","message":"archive not found"}}"#)
    let client = DaemonControlClient(socketURL: socketURL)

    XCTAssertFalse(client.delete(id: "2099-01-01T000000Z-1"))
  }

  func testDeleteRejectsEmptyIdLocallyWithoutHittingServer() {
    let client = DaemonControlClient(socketURL: socketURL)
    XCTAssertFalse(client.delete(id: ""))
  }

  // MARK: - Helpers

  private func startFakeServer(response: String) throws -> FakeUnixSocketServer {
    let server = try FakeUnixSocketServer(socketURL: socketURL, response: response)
    try server.start()
    return server
  }
}

private final class FakeUnixSocketServer {
  let socketURL: URL
  let response: String
  private let queue = DispatchQueue(label: "com.imu.fake-server")
  private let lock = NSLock()
  private var listenFD: Int32 = -1
  private var capturedRequest = Data()
  private var stopped = false

  init(socketURL: URL, response: String) throws {
    self.socketURL = socketURL
    self.response = response
  }

  func start() throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw NSError(domain: "FakeUnixSocketServer", code: 1)
    }

    _ = Darwin.unlink(socketURL.path)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketURL.path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
      let buffer = rawBuffer.bindMemory(to: CChar.self)
      for index in pathBytes.indices {
        buffer[index] = pathBytes[index]
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0, Darwin.listen(fd, 4) == 0 else {
      Darwin.close(fd)
      throw NSError(domain: "FakeUnixSocketServer", code: 2)
    }

    listenFD = fd
    queue.async { [weak self] in
      self?.acceptLoop()
    }
  }

  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    if listenFD >= 0 {
      Darwin.shutdown(listenFD, SHUT_RDWR)
      Darwin.close(listenFD)
      listenFD = -1
    }
    _ = Darwin.unlink(socketURL.path)
  }

  func lastRequest() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return capturedRequest
  }

  private func acceptLoop() {
    while true {
      lock.lock()
      let isStopped = stopped
      lock.unlock()
      if isStopped {
        return
      }

      var clientAddr = sockaddr()
      var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
      let clientFD = Darwin.accept(listenFD, &clientAddr, &clientLen)
      if clientFD < 0 {
        return
      }
      handleClient(fd: clientFD)
      Darwin.close(clientFD)
    }
  }

  private func handleClient(fd: Int32) {
    var buffer = Data()
    var byte: UInt8 = 0
    while buffer.count < 4096 {
      let n = Darwin.recv(fd, &byte, 1, 0)
      if n <= 0 { break }
      if byte == 0x0A { break }
      buffer.append(byte)
    }

    lock.lock()
    capturedRequest = buffer
    lock.unlock()

    var payload = Data(response.utf8)
    payload.append(0x0A)
    payload.withUnsafeBytes { ptr in
      _ = Darwin.send(fd, ptr.baseAddress, payload.count, 0)
    }
  }
}
