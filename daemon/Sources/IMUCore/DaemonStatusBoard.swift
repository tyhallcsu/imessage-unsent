import Foundation

public struct DaemonStatusSnapshot: Equatable {
  public let startedAt: Date
  public let lastWalChangeAt: Date?
  public let lastWalSize: Int64
  public let recoveryCount: Int
  public let lastError: String?

  public init(
    startedAt: Date,
    lastWalChangeAt: Date?,
    lastWalSize: Int64,
    recoveryCount: Int,
    lastError: String?
  ) {
    self.startedAt = startedAt
    self.lastWalChangeAt = lastWalChangeAt
    self.lastWalSize = lastWalSize
    self.recoveryCount = recoveryCount
    self.lastError = lastError
  }
}

public final class DaemonStatusBoard {
  private let lock = NSLock()
  private var startedAt: Date
  private var lastWalChangeAt: Date?
  private var lastWalSize: Int64 = 0
  private var recoveryCount: Int = 0
  private var lastError: String?

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

  public func snapshot() -> DaemonStatusSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return DaemonStatusSnapshot(
      startedAt: startedAt,
      lastWalChangeAt: lastWalChangeAt,
      lastWalSize: lastWalSize,
      recoveryCount: recoveryCount,
      lastError: lastError
    )
  }
}
