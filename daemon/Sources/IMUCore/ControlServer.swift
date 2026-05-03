import Darwin
import Dispatch
import Foundation

public enum ControlServerError: Error, LocalizedError {
  case pathTooLong(String)
  case socketCreationFailed(String)
  case bindFailed(String)
  case listenFailed(String)
  case alreadyStarted

  public var errorDescription: String? {
    switch self {
    case let .pathTooLong(path):
      return "control socket path too long: \(path)"
    case let .socketCreationFailed(message):
      return "failed to create control socket: \(message)"
    case let .bindFailed(message):
      return "failed to bind control socket: \(message)"
    case let .listenFailed(message):
      return "failed to listen on control socket: \(message)"
    case .alreadyStarted:
      return "control server already started"
    }
  }
}

public final class ControlServer {
  public let socketPath: URL
  private let statusBoard: DaemonStatusBoard
  private let historyReader: ArchiveHistoryReader
  private let version: String
  private let dataDir: URL
  private let notificationsShow: Bool
  private let logger: ((String) -> Void)?

  private let lifecycleQueue = DispatchQueue(label: "com.imu.control.lifecycle")
  private let acceptQueue = DispatchQueue(label: "com.imu.control.accept")
  private let clientQueue = DispatchQueue(label: "com.imu.control.client", attributes: .concurrent)
  private let clientSemaphore = DispatchSemaphore(value: 4)

  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var started = false

  public init(
    socketPath: URL,
    statusBoard: DaemonStatusBoard,
    historyReader: ArchiveHistoryReader,
    version: String = imuDaemonVersion,
    dataDir: URL,
    notificationsShow: Bool,
    logger: ((String) -> Void)? = nil
  ) {
    self.socketPath = socketPath
    self.statusBoard = statusBoard
    self.historyReader = historyReader
    self.version = version
    self.dataDir = dataDir
    self.notificationsShow = notificationsShow
    self.logger = logger
  }

  deinit {
    stop()
  }

  public func start() throws {
    try lifecycleQueue.sync {
      guard !started else {
        throw ControlServerError.alreadyStarted
      }

      let parent = socketPath.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )

      let path = socketPath.path
      var addr = sockaddr_un()
      let pathBytes = Array(path.utf8CString)
      let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
      guard pathBytes.count <= sunPathSize else {
        throw ControlServerError.pathTooLong(path)
      }

      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else {
        throw ControlServerError.socketCreationFailed(Self.errnoString())
      }

      // Best-effort cleanup of stale socket file.
      _ = Darwin.unlink(path)

      addr.sun_family = sa_family_t(AF_UNIX)
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
      guard bindResult == 0 else {
        let message = Self.errnoString()
        Darwin.close(fd)
        throw ControlServerError.bindFailed(message)
      }

      _ = Darwin.chmod(path, 0o600)

      guard Darwin.listen(fd, 4) == 0 else {
        let message = Self.errnoString()
        Darwin.close(fd)
        _ = Darwin.unlink(path)
        throw ControlServerError.listenFailed(message)
      }

      let flags = fcntl(fd, F_GETFL, 0)
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
      source.setEventHandler { [weak self] in
        self?.acceptPendingConnections()
      }
      source.resume()

      listenFD = fd
      acceptSource = source
      started = true
      logger?("control server listening path=\(path)")
    }
  }

  public func stop() {
    lifecycleQueue.sync {
      guard started else {
        return
      }
      acceptSource?.cancel()
      acceptSource = nil
      if listenFD >= 0 {
        Darwin.close(listenFD)
        listenFD = -1
      }
      _ = Darwin.unlink(socketPath.path)
      started = false
      logger?("control server stopped")
    }
  }

  private func acceptPendingConnections() {
    while true {
      var clientAddr = sockaddr()
      var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
      let clientFD = Darwin.accept(listenFD, &clientAddr, &clientLen)
      if clientFD < 0 {
        // EAGAIN / EWOULDBLOCK once the pending queue is drained.
        break
      }
      // accept(2) on Darwin inherits the listen socket's O_NONBLOCK onto the
      // accepted FD. We want blocking semantics on the client FD so SO_RCVTIMEO
      // governs read timeouts instead of recv() returning EAGAIN immediately.
      let clientFlags = fcntl(clientFD, F_GETFL, 0)
      _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)

      if clientSemaphore.wait(timeout: .now()) == .timedOut {
        Darwin.close(clientFD)
        continue
      }
      clientQueue.async { [weak self] in
        defer {
          Darwin.close(clientFD)
          self?.clientSemaphore.signal()
        }
        self?.handleClient(fd: clientFD)
      }
    }
  }

  private func handleClient(fd: Int32) {
    Self.setReadWriteTimeout(fd: fd, seconds: 2)

    guard let line = Self.readLine(fd: fd, maxBytes: 4096) else {
      writeResponse(fd: fd, data: makeError(code: "bad_request", message: "empty or oversized request"))
      return
    }

    let response = dispatch(line: line)
    writeResponse(fd: fd, data: response)
  }

  private func dispatch(line: Data) -> Data {
    if let first = line.first, first == 0x7B /* '{' */ {
      return dispatchJSON(line: line)
    }
    let plain = String(data: line, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if plain == "ping" {
      return makePing()
    }
    return makeError(code: "bad_request", message: "unrecognized request")
  }

  private func dispatchJSON(line: Data) -> Data {
    guard let parsed = try? JSONSerialization.jsonObject(with: line),
          let object = parsed as? [String: Any] else {
      return makeError(code: "bad_request", message: "malformed JSON")
    }
    guard let op = object["op"] as? String else {
      return makeError(code: "bad_request", message: "missing op")
    }
    switch op {
    case "ping":
      return makePing()
    case "status":
      return makeStatus()
    case "recent":
      let raw = (object["limit"] as? Int) ?? 5
      let limit = max(1, min(50, raw))
      return makeRecent(limit: limit)
    default:
      return makeError(
        code: "read_only",
        message: "op \(op) is not permitted: control server is read-only"
      )
    }
  }

  private func makePing() -> Data {
    encodeJSON(["ok": true, "pong": true])
  }

  private func makeStatus() -> Data {
    let snap = statusBoard.snapshot()
    let now = Date()
    let status: [String: Any] = [
      "state": "watching",
      "version": version,
      "started_at": Self.isoString(snap.startedAt),
      "uptime_seconds": Int(max(0, now.timeIntervalSince(snap.startedAt))),
      "last_wal_change_at": snap.lastWalChangeAt.map(Self.isoString) as Any? ?? NSNull(),
      "last_wal_size": snap.lastWalSize,
      "recovery_count": snap.recoveryCount,
      "last_error": snap.lastError as Any? ?? NSNull(),
      "data_dir": dataDir.path,
      "notifications_show": notificationsShow
    ]
    return encodeJSON(["ok": true, "status": status])
  }

  private func makeRecent(limit: Int) -> Data {
    let entries = historyReader.recent(limit: limit)
    let recoveries: [[String: Any]] = entries.map { entry in
      [
        "id": entry.id,
        "detected_at": entry.detectedAt,
        "handle": entry.handle,
        "rowid": entry.rowid,
        "recovered": entry.recovered,
        "text": entry.text as Any? ?? NSNull(),
        "error": entry.error as Any? ?? NSNull(),
        "archive_path": entry.archivePath
      ]
    }
    return encodeJSON(["ok": true, "recoveries": recoveries])
  }

  private func makeError(code: String, message: String) -> Data {
    encodeJSON(["ok": false, "error": ["code": code, "message": message]])
  }

  private func encodeJSON(_ payload: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
  }

  private func writeResponse(fd: Int32, data: Data) {
    var payload = data
    payload.append(0x0A) // newline
    payload.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < payload.count {
        let written = Darwin.send(fd, base.advanced(by: offset), payload.count - offset, 0)
        if written <= 0 {
          return
        }
        offset += written
      }
    }
  }

  private static func readLine(fd: Int32, maxBytes: Int) -> Data? {
    var buffer = Data()
    var byte: UInt8 = 0
    while buffer.count < maxBytes {
      let n = Darwin.recv(fd, &byte, 1, 0)
      if n <= 0 {
        return buffer.isEmpty ? nil : buffer
      }
      if byte == 0x0A { // '\n'
        return buffer
      }
      buffer.append(byte)
    }
    return nil
  }

  private static func setReadWriteTimeout(fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  }

  private static func errnoString() -> String {
    String(cString: strerror(errno))
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()

  private static func isoString(_ date: Date) -> String {
    isoFormatter.string(from: date)
  }
}
