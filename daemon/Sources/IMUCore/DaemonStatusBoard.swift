import Foundation

public struct DaemonStatusSnapshot: Equatable {
  public let startedAt: Date
  public let lastWalChangeAt: Date?
  public let lastWalSize: Int64
  public let recoveryCount: Int
  public let lastError: String?
  /// Result of the daemon's most recent attempt to open `chat.db`. Distinct
  /// from `lastError` because a stat-only success can coexist with an
  /// open-failure under TCC; nil means the daemon has not yet probed.
  public let chatDBReadable: Bool?
  public let chatDBProbedAt: Date?

  public init(
    startedAt: Date,
    lastWalChangeAt: Date?,
    lastWalSize: Int64,
    recoveryCount: Int,
    lastError: String?,
    chatDBReadable: Bool? = nil,
    chatDBProbedAt: Date? = nil
  ) {
    self.startedAt = startedAt
    self.lastWalChangeAt = lastWalChangeAt
    self.lastWalSize = lastWalSize
    self.recoveryCount = recoveryCount
    self.lastError = lastError
    self.chatDBReadable = chatDBReadable
    self.chatDBProbedAt = chatDBProbedAt
  }
}

public final class DaemonStatusBoard {
  private let lock = NSLock()
  private var startedAt: Date
  private var lastWalChangeAt: Date?
  private var lastWalSize: Int64 = 0
  private var recoveryCount: Int = 0
  private var lastError: String?
  private var chatDBReadable: Bool?
  private var chatDBProbedAt: Date?

  public init(now: Date = Date()) {
    self.startedAt = now
  }

  public func recordStart(at date: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    startedAt = date
    lastWalChangeAt = nil
    lastWalSize = 0
    recoveryCount = 0
    lastError = nil
    chatDBReadable = nil
    chatDBProbedAt = nil
  }

  public func recordWalChange(size: Int64, at date: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    lastWalChangeAt = date
    lastWalSize = size
  }

  public func recordRecovery() {
    lock.lock()
    defer { lock.unlock() }
    recoveryCount += 1
    lastError = nil
  }

  public func recordError(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    lastError = message
  }

  public func recordChatDBProbe(readable: Bool, at date: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    chatDBReadable = readable
    chatDBProbedAt = date
  }

  public func snapshot() -> DaemonStatusSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return DaemonStatusSnapshot(
      startedAt: startedAt,
      lastWalChangeAt: lastWalChangeAt,
      lastWalSize: lastWalSize,
      recoveryCount: recoveryCount,
      lastError: lastError,
      chatDBReadable: chatDBReadable,
      chatDBProbedAt: chatDBProbedAt
    )
  }
}
