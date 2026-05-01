import Foundation

public final class SnapshotPipeline {
  private let paths: IMUPaths
  private let config: DaemonConfig
  private let archiveStore: ArchiveStore

  public init(paths: IMUPaths, config: DaemonConfig) {
    self.paths = paths
    self.config = config
    self.archiveStore = ArchiveStore(archivesDir: paths.archivesDir)
  }

  public func run(event: RetractionEvent) throws -> RecoveryComplete {
    try paths.ensureDirectories()
    let startedAt = Date()
    let archiveID = "\(Self.archiveStamp(startedAt))-\(event.rowid)"
    let archiveDir = paths.archivesDir.appendingPathComponent(archiveID, isDirectory: true)
    try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    var snapFiles: [String: Manifest.SnapshotFile] = [:]
    for name in ["chat.db", "chat.db-wal", "chat.db-shm"] {
      let source = paths.messagesDir.appendingPathComponent(name)
      let destination = archiveDir.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      snapFiles[name] = Manifest.SnapshotFile(
        size: UInt64(values.fileSize ?? 0),
        mtime: values.contentModificationDate ?? Date()
      )
    }

    let finishedAt = Date()
    let manifest = Manifest(
      detectedAt: startedAt,
      rowid: event.rowid,
      guid: event.guid,
      handle: event.handle,
      snapshotStartedAt: startedAt,
      snapshotFinishedAt: finishedAt,
      snapFiles: snapFiles
    )
    try JSONEncoder.pretty.encode(manifest).write(to: archiveDir.appendingPathComponent("manifest.json"), options: .atomic)

    let recovery = try runRecovery(event: event, archiveDir: archiveDir)
    try recovery.write(to: archiveDir.appendingPathComponent("recovery.json"), options: .atomic)
    try archiveStore.prune(keepLast: config.retentionLimit)

    let recovered = Self.recoveredText(from: recovery) != nil
    return RecoveryComplete(archiveID: archiveID, archiveDir: archiveDir.path, recovered: recovered)
  }

  private func runRecovery(event: RetractionEvent, archiveDir: URL) throws -> Data {
    let process = Process()
    process.executableURL = paths.recoverScript
    process.arguments = [
      "--handle", event.handle,
      "--rowid", "\(event.rowid)",
      "--work", archiveDir.path,
      "--no-snapshot",
      "--json"
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus == 0, !output.isEmpty {
      return output
    }
    let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "recover.sh failed"
    let fallback: [String: Any] = [
      "schema_version": 1,
      "handle": event.handle,
      "candidate": ["rowid": event.rowid, "guid": event.guid],
      "recovered": ["text_b64": NSNull(), "length": NSNull(), "source": NSNull(), "wal_offset": NSNull()],
      "error": message
    ]
    return try JSONSerialization.data(withJSONObject: fallback, options: [.prettyPrinted, .sortedKeys])
  }

  public static func recoveredText(from data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let recovered = object["recovered"] as? [String: Any],
          let textB64 = recovered["text_b64"] as? String,
          let textData = Data(base64Encoded: textB64) else {
      return nil
    }
    return String(data: textData, encoding: .utf8)
  }

  private static func archiveStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }
}
