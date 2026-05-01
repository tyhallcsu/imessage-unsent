import Darwin
import Foundation
import XCTest
@testable import IMUCore

final class UnixSocketServerTests: XCTestCase {
  func testServerRespondsToPingRequest() throws {
    let socketURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sock")
    let server = UnixSocketServer(socketURL: socketURL) { request in
      XCTAssertEqual(request.method, "GET")
      XCTAssertEqual(request.path, "/ping")
      return HTTPResponse(body: Data(#"{"ok":true}"#.utf8))
    }
    try server.start()
    defer { server.stop() }

    let response = try sendRawRequest(socketPath: socketURL.path, request: "GET /ping HTTP/1.1\r\nHost: local\r\n\r\n")
    XCTAssertTrue(response.contains(#""ok":true"#))
  }

  private func sendRawRequest(socketPath: String, request: String) throws -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    XCTAssertLessThan(pathBytes.count, capacity)
    withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
        for index in pathBytes.indices {
          chars[index] = CChar(bitPattern: pathBytes[index])
        }
        chars[pathBytes.count] = 0
      }
    }

    let connected = withUnsafePointer(to: &addr) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    XCTAssertEqual(connected, 0)

    try request.withCString { pointer in
      if write(fd, pointer, strlen(pointer)) < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if count == 0 { break }
      response.append(buffer, count: count)
    }
    return String(data: response, encoding: .utf8) ?? ""
  }
}
