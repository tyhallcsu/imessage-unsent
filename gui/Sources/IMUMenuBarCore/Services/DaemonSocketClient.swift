import Darwin
import Foundation

public protocol DaemonPinging {
  func ping() -> Bool
}

public struct DaemonSocketClient: DaemonPinging {
  public let socketURL: URL

  public init(socketURL: URL = defaultDaemonSocketURL()) {
    self.socketURL = socketURL
  }

  public func ping() -> Bool {
    let path = socketURL.path
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      return false
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return false
    }
    defer {
      close(fd)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
      let buffer = rawBuffer.bindMemory(to: CChar.self)
      for index in pathBytes.indices {
        buffer[index] = pathBytes[index]
      }
    }

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    guard result == 0 else {
      return false
    }

    _ = "ping\n".withCString { write(fd, $0, strlen($0)) }
    return true
  }
}

public func defaultDaemonSocketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("daemon.sock", isDirectory: false)
}
