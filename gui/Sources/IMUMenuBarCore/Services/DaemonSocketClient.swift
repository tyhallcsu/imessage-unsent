import Darwin
import Foundation

public protocol DaemonPinging {
  func ping() -> Bool
}

public protocol DaemonControlClienting: DaemonPinging {
  func status() -> DaemonStatusInfo?
  func recent(limit: Int) -> [ArchiveHistoryEntryDTO]
}

public final class DaemonControlClient: DaemonControlClienting {
  public let socketURL: URL
  private let timeoutSeconds: Int

  public init(socketURL: URL = defaultDaemonSocketURL(), timeoutSeconds: Int = 1) {
    self.socketURL = socketURL
    self.timeoutSeconds = timeoutSeconds
  }

  public func ping() -> Bool {
    guard let response = sendRequest(["op": "ping"]) else {
      return false
    }
    return (response["ok"] as? Bool) == true
  }

  public func status() -> DaemonStatusInfo? {
    guard let response = sendRequest(["op": "status"]),
          (response["ok"] as? Bool) == true,
          let statusObject = response["status"] as? [String: Any] else {
      return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: statusObject) else {
      return nil
    }
    return try? JSONDecoder().decode(DaemonStatusInfo.self, from: data)
  }

  public func recent(limit: Int) -> [ArchiveHistoryEntryDTO] {
    let payload: [String: Any] = ["op": "recent", "limit": max(1, min(50, limit))]
    guard let response = sendRequest(payload),
          (response["ok"] as? Bool) == true,
          let recoveries = response["recoveries"] as? [[String: Any]] else {
      return []
    }
    return recoveries.compactMap { entry in
      guard let data = try? JSONSerialization.data(withJSONObject: entry) else {
        return nil
      }
      return try? JSONDecoder().decode(ArchiveHistoryEntryDTO.self, from: data)
    }
  }

  private func sendRequest(_ payload: [String: Any]) -> [String: Any]? {
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
      return nil
    }
    guard let response = exchange(body: body) else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
  }

  private func exchange(body: Data) -> Data? {
    let path = socketURL.path
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      return nil
    }

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return nil
    }
    defer {
      Darwin.close(fd)
    }

    var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
      let buffer = rawBuffer.bindMemory(to: CChar.self)
      for index in pathBytes.indices {
        buffer[index] = pathBytes[index]
      }
    }

    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      return nil
    }

    var outgoing = body
    outgoing.append(0x0A) // newline
    let sent = outgoing.withUnsafeBytes { ptr -> Int in
      var offset = 0
      while offset < outgoing.count {
        let written = Darwin.send(fd, ptr.baseAddress?.advanced(by: offset), outgoing.count - offset, 0)
        if written <= 0 {
          return offset
        }
        offset += written
      }
      return offset
    }
    guard sent == outgoing.count else {
      return nil
    }

    var buffer = Data()
    var byte: UInt8 = 0
    while buffer.count < 65_536 {
      let n = Darwin.recv(fd, &byte, 1, 0)
      if n <= 0 {
        break
      }
      if byte == 0x0A {
        break
      }
      buffer.append(byte)
    }
    return buffer.isEmpty ? nil : buffer
  }
}

public struct DaemonSocketClient: DaemonPinging {
  public let client: DaemonControlClient

  public init(socketURL: URL = defaultDaemonSocketURL()) {
    self.client = DaemonControlClient(socketURL: socketURL)
  }

  public init(client: DaemonControlClient) {
    self.client = client
  }

  public var socketURL: URL {
    client.socketURL
  }

  public func ping() -> Bool {
    client.ping()
  }
}

public func defaultDaemonSocketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("daemon.sock", isDirectory: false)
}
