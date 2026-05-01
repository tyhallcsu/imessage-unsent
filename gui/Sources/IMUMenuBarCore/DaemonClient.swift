import Darwin
import Foundation

public protocol SocketTransport {
  func send(method: String, path: String) throws -> Data
}

public final class UnixSocketTransport: SocketTransport {
  public let socketPath: String

  public init(socketPath: String) {
    self.socketPath = socketPath
  }

  public func send(method: String, path: String) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
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

    let connected = withUnsafePointer(to: &addr) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }

    let request = "\(method) \(path) HTTP/1.1\r\nHost: imessage-unsent\r\nConnection: close\r\n\r\n"
    try request.withCString { pointer in
      let written = write(fd, pointer, strlen(pointer))
      if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      if count == 0 { break }
      response.append(buffer, count: count)
    }
    guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return response }
    return response[split.upperBound...]
  }
}

public final class DaemonClient {
  private let transport: SocketTransport
  private let decoder: JSONDecoder

  public init(transport: SocketTransport) {
    self.transport = transport
    self.decoder = JSONDecoder()
    self.decoder.dateDecodingStrategy = .iso8601
  }

  public convenience init(socketPath: String = "\(NSHomeDirectory())/Library/Application Support/imessage-unsent/daemon.sock") {
    self.init(transport: UnixSocketTransport(socketPath: socketPath))
  }

  public func ping() throws -> WatchStatus {
    try decoder.decode(WatchStatus.self, from: transport.send(method: "GET", path: "/ping"))
  }

  public func archives(page: Int = 1, limit: Int = 50) throws -> ArchiveListResponse {
    try decoder.decode(ArchiveListResponse.self, from: transport.send(method: "GET", path: "/archives?page=\(page)&limit=\(limit)"))
  }

  public func recovery(id: String) throws -> RecoveryDetail {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    return try decoder.decode(RecoveryDetail.self, from: transport.send(method: "GET", path: "/archives/\(encoded)"))
  }

  public func deleteArchive(id: String) throws {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
    _ = try transport.send(method: "DELETE", path: "/archives/\(encoded)")
  }
}
