import Darwin
import Dispatch
import Foundation

public enum ControlServerError: Error, LocalizedError {
  case pathTooLong(String)
  case socketCreationFailed(String)
  case bindFailed(String)
  case listenFailed(String)
  case alreadyStarted
  case socketInUse(String)

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
    case let .socketInUse(path):
      return "another control server is already listening at \(path) — refusing to steal its socket"
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

  private var acceptSource: DispatchSourceRead?
  // Signaled by the accept source's cancel handler once the listen fd has been
  // closed, so stop() can block until teardown is truly complete.
  private var acceptCancelSemaphore: DispatchSemaphore?
  private var started = false
  // Inode of the socket file THIS server bound. stop() only unlinks the path
  // while it still points at our inode — another process may have replaced
  // the file, and deleting theirs takes a healthy server offline (#141).
  // Guarded by lifecycleQueue like the rest of the lifecycle state.
  private var boundInode: ino_t?

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

      // Reclaim the path ONLY when no listener answers. Unconditional unlink
      // let a second daemon instance silently steal the socket out from under
      // the healthy LaunchAgent (#141): the old server kept serving an
      // orphaned inode while every new client reached the newcomer.
      if FileManager.default.fileExists(atPath: path) {
        if Self.socketHasListener(path: path, pathBytes: pathBytes) {
          Darwin.close(fd)
          throw ControlServerError.socketInUse(path)
        }
        _ = Darwin.unlink(path)
      }

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

      var boundStat = stat()
      boundInode = lstat(path, &boundStat) == 0 ? boundStat.st_ino : nil

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
        // Use the captured `fd`, never an instance field: reading a mutable
        // `listenFD` off the accept queue while stop() rewrote it was a data
        // race (#124, confirmed by ThreadSanitizer at the accept(2) call).
        self?.acceptPendingConnections(listenFD: fd)
      }
      // Close the listen fd ONLY from the cancel handler. libdispatch guarantees
      // this runs after the source is fully torn down (no in-flight or future
      // event handlers), so the fd is never closed out from under a live
      // DispatchSourceRead — that misuse is what traps (SIGTRAP) under fd reuse
      // in the full test suite (#124). The semaphore lets stop() wait for it.
      let cancelSemaphore = DispatchSemaphore(value: 0)
      source.setCancelHandler {
        Darwin.close(fd)
        cancelSemaphore.signal()
      }
      source.resume()

      acceptSource = source
      acceptCancelSemaphore = cancelSemaphore
      started = true
      logger?("control server listening path=\(path)")
    }
  }

  public func stop() {
    lifecycleQueue.sync {
      guard started else {
        return
      }
      started = false
      let source = acceptSource
      let cancelSemaphore = acceptCancelSemaphore
      acceptSource = nil
      acceptCancelSemaphore = nil
      var currentStat = stat()
      if let boundInode,
         lstat(socketPath.path, &currentStat) == 0,
         currentStat.st_ino == boundInode {
        _ = Darwin.unlink(socketPath.path)
      }
      boundInode = nil
      // Cancel the accept source and wait (bounded) for its cancel handler to
      // close the listen fd. This makes teardown deterministic and guarantees
      // libdispatch is finished with the fd before it can be reused (#124).
      source?.cancel()
      if source != nil {
        _ = cancelSemaphore?.wait(timeout: .now() + 2)
      }
      logger?("control server stopped")
    }
  }

  private func acceptPendingConnections(listenFD: Int32) {
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

      // A client that disconnects between request and response (GUI force
      // quit, Ctrl-C'd nc) must yield EPIPE from send(2), not a SIGPIPE that
      // kills the whole daemon (#141).
      var noSigPipe: Int32 = 1
      _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

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
    case "delete":
      return makeDelete(id: object["id"] as? String)
    case "compact":
      return makeCompact(id: object["id"] as? String)
    default:
      return makeError(
        code: "read_only",
        message: "op \(op) is not permitted: control server only allows ping/status/recent/delete/compact"
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
      "notifications_show": notificationsShow,
      "chat_db_readable": snap.chatDBReadable as Any? ?? NSNull(),
      "chat_db_probed_at": snap.chatDBProbedAt.map(Self.isoString) as Any? ?? NSNull()
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
        "archive_path": entry.archivePath,
        "compaction_state": entry.compactionState as Any? ?? NSNull()
      ]
    }
    return encodeJSON(["ok": true, "recoveries": recoveries])
  }

  private func makeDelete(id: String?) -> Data {
    guard let id, !id.isEmpty else {
      return makeError(code: "bad_request", message: "missing or empty id")
    }
    let nsId = id as NSString
    let isWellFormed = ArchiveHistoryReader.archiveDirectoryNamePattern.firstMatch(
      in: id,
      range: NSRange(location: 0, length: nsId.length)
    ) != nil
    guard isWellFormed else {
      return makeError(code: "bad_request", message: "invalid archive id")
    }
    let target = historyReader.archivesDir.appendingPathComponent(id, isDirectory: true)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
      return makeError(code: "not_found", message: "archive not found")
    }
    do {
      try FileManager.default.removeItem(at: target)
    } catch {
      return makeError(code: "internal_error", message: "delete failed: \(error.localizedDescription)")
    }
    return encodeJSON(["ok": true, "deleted": id])
  }

  private func makeCompact(id: String?) -> Data {
    guard let id, !id.isEmpty else {
      return makeError(code: "bad_request", message: "missing or empty id")
    }
    let nsId = id as NSString
    let isWellFormed = ArchiveHistoryReader.archiveDirectoryNamePattern.firstMatch(
      in: id,
      range: NSRange(location: 0, length: nsId.length)
    ) != nil
    guard isWellFormed else {
      return makeError(code: "bad_request", message: "invalid archive id")
    }
    let target = historyReader.archivesDir.appendingPathComponent(id, isDirectory: true)
    do {
      let result = try ArchiveCompactor.compact(archiveDir: target)
      logger?("compact ok id=\(id) bytes_reclaimed=\(result.bytesReclaimed) removed=\(result.removedFiles.count)")
      return encodeJSON([
        "ok": true,
        "compacted": id,
        "bytes_reclaimed": result.bytesReclaimed,
        "removed_files": result.removedFiles
      ])
    } catch let error as ArchiveCompactionError {
      let code: String
      switch error {
      case .archiveNotFound: code = "not_found"
      case .alreadyCompacted: code = "already_compacted"
      case .manifestUnreadable, .recoveryUnreadable: code = "bad_request"
      case .writeFailed: code = "internal_error"
      }
      return makeError(code: code, message: error.localizedDescription)
    } catch {
      return makeError(code: "internal_error", message: "compact failed: \(error.localizedDescription)")
    }
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

  /// True when a live server is accepting on `path`. connect(2) on a Unix
  /// socket resolves locally and immediately: success means a listener owns
  /// the file; ECONNREFUSED/ENOENT mean the file is stale and safe to unlink.
  private static func socketHasListener(path: String, pathBytes: [CChar]) -> Bool {
    let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probeFD >= 0 else {
      return false
    }
    defer { Darwin.close(probeFD) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
      let buffer = rawBuffer.bindMemory(to: CChar.self)
      for index in pathBytes.indices {
        buffer[index] = pathBytes[index]
      }
    }
    let result = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(probeFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return result == 0
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
