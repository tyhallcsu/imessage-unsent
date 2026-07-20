import Foundation

/// Issue #67. Captures `chat.db-wal` to a rolling on-disk buffer every time
/// it changes, so when a retraction is detected the daemon can scan a window
/// of pre-retract WAL states — not just the live WAL, which may have been
/// checkpointed away by SQLite before we get a chance to copy it.
///
/// Snapshots live at `<storeDir>/<UTC-iso-timestamp>-<size>.db-wal`. Retention
/// is bounded by both a count cap (default 30) and a max age (default 5 min).
/// The 2-minute iMessage unsend window is the practical upper bound on how
/// far back we ever need to look.
public final class WALSnapshotter {
  public let walURL: URL
  public let storeDir: URL
  public let retentionLimit: Int
  public let maxAge: TimeInterval

  private let queue: DispatchQueue
  private let fileManager: FileManager
  private let clock: () -> Date
  private var lastSnapshotSignature: WALChangeSignature = .absent

  public init(
    walURL: URL = defaultMessagesWalURL(),
    storeDir: URL,
    retentionLimit: Int = 30,
    maxAge: TimeInterval = 5 * 60,
    fileManager: FileManager = .default,
    clock: @escaping () -> Date = Date.init
  ) {
    self.walURL = walURL.standardizedFileURL
    self.storeDir = storeDir.standardizedFileURL
    self.retentionLimit = retentionLimit
    self.maxAge = maxAge
    self.queue = DispatchQueue(label: "com.imu.watcher.walsnap")
    self.fileManager = fileManager
    self.clock = clock
  }

  /// Snapshots the current WAL to the rolling buffer. No-op when the WAL is
  /// unchanged from the last successful snapshot — comparing the full change
  /// signature (size + nanosecond mtime + inode), not just size, so a same-size
  /// in-place frame overwrite in SQLite's post-checkpoint steady state IS
  /// captured (#111) while a genuinely idle WAL (FSEvents fired but nothing
  /// changed) is still skipped, keeping us from filling the disk.
  @discardableResult
  public func snapshot() throws -> URL? {
    try queue.sync {
      try ensureStoreDir()
      guard fileManager.fileExists(atPath: walURL.path) else {
        return nil
      }
      let signature = WALChangeSignature.read(at: walURL)
      let currentSize = signature.byteSize
      if currentSize <= 0 || signature == lastSnapshotSignature {
        return nil
      }

      let now = clock()
      let dest = storeDir.appendingPathComponent(
        "\(Self.fileTimestamp(now))-\(currentSize).db-wal",
        isDirectory: false
      )
      // Same-millisecond duplicate (rare; protect against it anyway).
      if fileManager.fileExists(atPath: dest.path) {
        return nil
      }

      try fileManager.copyItem(at: walURL, to: dest)
      // Pin the destination's mtime to `now` from our clock — `copyItem`
      // sets the new file's mtime to wall-clock time, which would diverge
      // from the injected clock under test and break maxAge math.
      try fileManager.setAttributes(
        [.posixPermissions: 0o600, .modificationDate: now],
        ofItemAtPath: dest.path
      )
      lastSnapshotSignature = signature
      try trim(now: now)
      return dest
    }
  }

  /// Copies the snapshots still inside the `maxAge` window into a fresh
  /// `wal-history/` directory under `destDir`. Used by `ArchivePipeline` to
  /// preserve the buffer state alongside each archived retraction.
  ///
  /// Age-filtered (#143 / F-M5): `trim` only runs on write activity, so after
  /// a quiet stretch the buffer can hold hours-stale snapshots — copying
  /// those into every archive multiplied disk use (retention × WAL size per
  /// archive) with zero forensic value; the pre-retract page is only ever in
  /// a snapshot younger than the unsend window.
  public func archiveTo(_ destDir: URL) throws {
    try queue.sync {
      try fileManager.createDirectory(
        at: destDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let cutoff = clock().addingTimeInterval(-maxAge)
      for snap in try listSnapshots() {
        guard
          let attrs = try? fileManager.attributesOfItem(atPath: snap.path),
          let mtime = attrs[.modificationDate] as? Date,
          mtime >= cutoff
        else {
          continue
        }
        let dest = destDir.appendingPathComponent(snap.lastPathComponent, isDirectory: false)
        if fileManager.fileExists(atPath: dest.path) {
          try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: snap, to: dest)
      }
    }
  }

  /// Age-based retention pass for quiet periods. `snapshot()` trims only on
  /// write activity, so without a periodic call stale snapshots would sit in
  /// the buffer indefinitely (#143). Called from the daemon heartbeat.
  public func trimExpired() {
    queue.sync {
      try? trim(now: clock())
    }
  }

  public func snapshotCount() -> Int {
    queue.sync {
      (try? listSnapshots())?.count ?? 0
    }
  }

  // MARK: - Internals

  private func ensureStoreDir() throws {
    try fileManager.createDirectory(
      at: storeDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func listSnapshots() throws -> [URL] {
    guard fileManager.fileExists(atPath: storeDir.path) else { return [] }
    return try fileManager.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".db-wal") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }  // oldest first
  }

  private func trim(now: Date) throws {
    let snapshots = try listSnapshots()
    let countCut = max(0, snapshots.count - retentionLimit)
    for url in snapshots.prefix(countCut) {
      try? fileManager.removeItem(at: url)
    }
    let cutoff = now.addingTimeInterval(-maxAge)
    for url in snapshots.dropFirst(countCut) {
      guard
        let attrs = try? fileManager.attributesOfItem(atPath: url.path),
        let mtime = attrs[.modificationDate] as? Date
      else {
        continue
      }
      if mtime < cutoff {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'.'SSS'Z'"
    return formatter
  }()

  static func fileTimestamp(_ date: Date) -> String {
    timestampFormatter.string(from: date)
  }
}
