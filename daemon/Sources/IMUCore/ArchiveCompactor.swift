import Foundation

public enum ArchiveCompactionError: Error, LocalizedError {
  case archiveNotFound(String)
  case manifestUnreadable(String)
  case recoveryUnreadable(String)
  case alreadyCompacted(String)
  case writeFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .archiveNotFound(path):
      return "archive directory not found: \(path)"
    case let .manifestUnreadable(reason):
      return "manifest.json could not be read: \(reason)"
    case let .recoveryUnreadable(reason):
      return "recovery.json could not be read or is empty — refusing to compact: \(reason)"
    case let .alreadyCompacted(name):
      return "archive \(name) is already compacted"
    case let .writeFailed(reason):
      return "failed to write updated manifest: \(reason)"
    }
  }
}

public struct ArchiveCompactionResult: Equatable {
  public let archiveDir: URL
  public let bytesReclaimed: Int64
  public let removedFiles: [String]

  public init(archiveDir: URL, bytesReclaimed: Int64, removedFiles: [String]) {
    self.archiveDir = archiveDir
    self.bytesReclaimed = bytesReclaimed
    self.removedFiles = removedFiles
  }
}

public enum ArchiveCompactor {
  /// Files preserved during compaction. Anything else in the archive directory
  /// is fair game to delete.
  public static let preservedFiles: Set<String> = [
    "manifest.json",
    "recovery.json",
    "recovery.stderr.txt",
    "report.txt"
  ]

  /// Drop the chat.db family + WAL history snapshots from a `live` archive,
  /// preserving the recovered text and metadata. Sets `compaction_state =
  /// "compacted"` on the manifest. Refuses to operate if `recovery.json` is
  /// missing or unparseable so we never lose the recovered text without
  /// confirmation.
  @discardableResult
  public static func compact(
    archiveDir: URL,
    fileManager: FileManager = .default,
    now: Date = Date()
  ) throws -> ArchiveCompactionResult {
    var isDir: ObjCBool = false
    guard
      fileManager.fileExists(atPath: archiveDir.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw ArchiveCompactionError.archiveNotFound(archiveDir.path)
    }

    let manifestURL = archiveDir.appendingPathComponent("manifest.json", isDirectory: false)
    guard let manifestData = try? Data(contentsOf: manifestURL),
          var manifest = try? JSONDecoder().decode(ArchiveManifest.self, from: manifestData) else {
      throw ArchiveCompactionError.manifestUnreadable(manifestURL.path)
    }

    if manifest.compactionState == "compacted" {
      throw ArchiveCompactionError.alreadyCompacted(archiveDir.lastPathComponent)
    }

    let recoveryURL = archiveDir.appendingPathComponent("recovery.json", isDirectory: false)
    guard let recoveryData = try? Data(contentsOf: recoveryURL), !recoveryData.isEmpty else {
      throw ArchiveCompactionError.recoveryUnreadable(recoveryURL.path)
    }

    var bytesReclaimed: Int64 = 0
    var removed: [String] = []
    var failedRemovals: [String] = []
    let contents = (try? fileManager.contentsOfDirectory(
      at: archiveDir,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    for url in contents {
      let name = url.lastPathComponent
      if Self.preservedFiles.contains(name) {
        continue
      }
      let size = directorySize(url, fileManager: fileManager)
      do {
        try fileManager.removeItem(at: url)
        bytesReclaimed += size
        removed.append(name)
      } catch {
        // Non-fatal, but it must be RECORDED: writing "compacted" while
        // bytes remain on disk made alreadyCompacted refuse every retry
        // forever and under-reported bytes_reclaimed (#144 / F-L7).
        failedRemovals.append(name)
        continue
      }
    }

    // "partial" stays retryable — the alreadyCompacted gate only fires on
    // "compacted", so a later compact can finish the job.
    manifest.compactionState = failedRemovals.isEmpty ? "compacted" : "partial"
    manifest.compactedAt = ISO8601DateFormatter.archiveCompactionISO.string(from: now)

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let updated = try encoder.encode(manifest)
      try updated.write(to: manifestURL, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    } catch {
      throw ArchiveCompactionError.writeFailed(error.localizedDescription)
    }

    return ArchiveCompactionResult(
      archiveDir: archiveDir,
      bytesReclaimed: bytesReclaimed,
      removedFiles: removed
    )
  }

  private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
      return 0
    }
    if !isDir.boolValue {
      let attrs = try? fileManager.attributesOfItem(atPath: url.path)
      return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
    var total: Int64 = 0
    let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    while let item = enumerator?.nextObject() as? URL {
      let attrs = try? fileManager.attributesOfItem(atPath: item.path)
      if let bytes = (attrs?[.size] as? NSNumber)?.int64Value {
        total += bytes
      }
    }
    return total
  }
}

private extension ISO8601DateFormatter {
  static let archiveCompactionISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
}
