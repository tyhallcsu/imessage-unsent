import Darwin
import Foundation

public struct HTTPRequest {
  public var method: String
  public var path: String
}

public struct HTTPResponse {
  public var status: Int
  public var body: Data
  public var contentType: String

  public init(status: Int = 200, body: Data, contentType: String = "application/json") {
    self.status = status
    self.body = body
    self.contentType = contentType
  }
}

public final class UnixSocketServer {
  private let socketURL: URL
  private let handler: (HTTPRequest) -> HTTPResponse
  private let queue = DispatchQueue(label: "com.imessage-unsent.socket", qos: .utility)
  private var fd: Int32 = -1
  private var running = false

  public init(socketURL: URL, handler: @escaping (HTTPRequest) -> HTTPResponse) {
    self.socketURL = socketURL
    self.handler = handler
  }

  deinit {
    stop()
  }

  public func start() throws {
    try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    unlink(socketURL.path)

    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketURL.path.utf8)
    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < sunPathCapacity else {
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { chars in
        for index in pathBytes.indices {
          chars[index] = CChar(bitPattern: pathBytes[index])
        }
        chars[pathBytes.count] = 0
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard listen(fd, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    running = true
    queue.async { [weak self] in self?.acceptLoop() }
  }

  public func stop() {
    running = false
    if fd >= 0 {
      close(fd)
      fd = -1
    }
    unlink(socketURL.path)
  }

  private func acceptLoop() {
    while running {
      let client = accept(fd, nil, nil)
      if client < 0 {
        continue
      }
      handle(client: client)
    }
  }

  private func handle(client: Int32) {
    defer { close(client) }
    var buffer = [UInt8](repeating: 0, count: 8192)
    let count = read(client, &buffer, buffer.count)
    guard count > 0 else { return }
    let requestText = String(decoding: buffer.prefix(count), as: UTF8.self)
    let firstLine = requestText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    let parts = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    let request = HTTPRequest(
      method: parts.count > 0 ? String(parts[0]) : "GET",
      path: parts.count > 1 ? String(parts[1]) : "/ping"
    )
    let response = handler(request)
    let statusText = response.status == 200 ? "OK" : "Error"
    var header = "HTTP/1.1 \(response.status) \(statusText)\r\n"
    header += "Content-Type: \(response.contentType)\r\n"
    header += "Content-Length: \(response.body.count)\r\n"
    header += "Connection: close\r\n\r\n"
    _ = header.withCString { write(client, $0, strlen($0)) }
    response.body.withUnsafeBytes { rawBuffer in
      if let base = rawBuffer.baseAddress {
        _ = write(client, base, response.body.count)
      }
    }
  }
}
