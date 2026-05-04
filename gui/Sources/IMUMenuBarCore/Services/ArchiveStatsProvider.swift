import Foundation

/// Lightweight on-disk statistics for an archive directory: byte size + file
/// count. The History view uses this to render a per-row size badge and a
/// total-storage summary in the header. Cached in memory keyed by archive id
/// because directory enumeration is mildly expensive (one stat per file).
public final class ArchiveStatsProvider {
  public struct Stats: Equatable {
    public let bytes: Int64
    public let fileCount: Int

    public init(bytes: Int64, fileCount: Int) {
      self.bytes = bytes
      self.fileCount = fileCount
    }

    public var humanSize: String {
      let formatter = ByteCountFormatter()
      formatter.allowedUnits = [.useKB, .useMB, .useGB]
      formatter.countStyle = .file
      return formatter.string(fromByteCount: bytes)
    }
  }

  private let archivesDir: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var cache: [String: Stats] = [:]

  public init(archivesDir: URL = defaultArchivesDir(), fileManager: FileManager = .default) {
    self.archivesDir = archivesDir
    self.fileManager = fileManager
  }

  public static func defaultArchivesDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("imessage-unsent", isDirectory: true)
      .appendingPathComponent("archives", isDirectory: true)
  }

  public func stats(forArchiveId id: String) -> Stats? {
    if let cached = readCache(id) { return cached }
    let dir = archivesDir.appendingPathComponent(id, isDirectory: true)
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    let stats = computeStats(at: dir)
    writeCache(id, stats)
    return stats
  }

  /// Sum of all archives' bytes + file counts, filtered to a list of ids.
  public func aggregate(forArchiveIds ids: [String]) -> Stats {
    var total: Int64 = 0
    var files = 0
    for id in ids {
      if let s = stats(forArchiveId: id) {
        total += s.bytes
        files += s.fileCount
      }
    }
    return Stats(bytes: total, fileCount: files)
  }

  /// Drop the cached size for a specific archive — call after compacting.
  public func invalidate(archiveId: String) {
    lock.lock()
    cache.removeValue(forKey: archiveId)
    lock.unlock()
  }

  public func invalidateAll() {
    lock.lock()
    cache.removeAll()
    lock.unlock()
  }

  private func readCache(_ id: String) -> Stats? {
    lock.lock()
    defer { lock.unlock() }
    return cache[id]
  }

  private func writeCache(_ id: String, _ stats: Stats) {
    lock.lock()
    cache[id] = stats
    lock.unlock()
  }

  private func computeStats(at dir: URL) -> Stats {
    var total: Int64 = 0
    var count = 0
    let enumerator = fileManager.enumerator(
      at: dir,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    while let item = enumerator?.nextObject() as? URL {
      let attrs = try? fileManager.attributesOfItem(atPath: item.path)
      if (attrs?[.type] as? FileAttributeType) == .typeDirectory { continue }
      if let bytes = (attrs?[.size] as? NSNumber)?.int64Value {
        total += bytes
        count += 1
      }
    }
    return Stats(bytes: total, fileCount: count)
  }
}
