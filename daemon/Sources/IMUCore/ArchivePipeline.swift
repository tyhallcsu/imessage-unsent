import Foundation

public struct RecoveryComplete: Equatable {
  public let archiveDir: URL
  public let recovered: Bool

  public init(archiveDir: URL, recovered: Bool) {
    self.archiveDir = archiveDir
    self.recovered = recovered
  }
}

public struct ArchivePipeline {
  public let liveMessagesDir: URL
  public let archivesDir: URL
  public let recoverScriptURL: URL
  public let retentionLimit: Int

  private let fileManager: FileManager

  public init(
    liveMessagesDir: URL = defaultMessagesDirURL(),
    archivesDir: URL,
    recoverScriptURL: URL = defaultRecoverScriptURL(),
    retentionLimit: Int = 100,
    fileManager: FileManager = .default
  ) {
    self.liveMessagesDir = liveMessagesDir
    self.archivesDir = archivesDir
    self.recoverScriptURL = recoverScriptURL
    self.retentionLimit = retentionLimit
    self.fileManager = fileManager
  }

  public func archive(event: RetractionDetected, detectedAt: Date = Date()) throws -> RecoveryComplete {
    try ensurePrivateDirectory(archivesDir)

    let archiveDir = archivesDir
      .appendingPathComponent(Self.archiveDirectoryName(date: detectedAt, rowid: event.rowid), isDirectory: true)
    try ensurePrivateDirectory(archiveDir)

    let snapshotStartedAt = Date()
    let snapFiles = try snapshotChatDBFamily(to: archiveDir)
    let snapshotFinishedAt = Date()
    var manifest = ArchiveManifest(
      detectedAt: isoString(detectedAt),
      rowid: event.rowid,
      guid: event.guid,
      handle: event.handle,
      editedAt: event.editedAt,
      snapshotStartedAt: isoString(snapshotStartedAt),
      snapshotFinishedAt: isoString(snapshotFinishedAt),
      snapFiles: snapFiles,
      recovery: nil
    )
    try writeManifest(manifest, to: archiveDir)

    let recovery = runRecovery(event: event, archiveDir: archiveDir)
    manifest.recovery = recovery.manifest
    try writeManifest(manifest, to: archiveDir)
    try pruneArchives()

    return RecoveryComplete(archiveDir: archiveDir, recovered: recovery.manifest.recovered)
  }

  public func pruneArchives() throws {
    guard retentionLimit >= 0, fileManager.fileExists(atPath: archivesDir.path) else {
      return
    }

    let archiveURLs = try fileManager.contentsOfDirectory(
      at: archivesDir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    .filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }

    for url in archiveURLs.dropFirst(retentionLimit) {
      try fileManager.removeItem(at: url)
    }
  }

  public static func archiveDirectoryName(date: Date, rowid: Int64) -> String {
    "\(compactTimestamp(date))-\(rowid)"
  }

  private func snapshotChatDBFamily(to archiveDir: URL) throws -> [String: ArchiveSnapFile] {
    var files: [String: ArchiveSnapFile] = [:]

    for name in ["chat.db", "chat.db-wal", "chat.db-shm"] {
      let source = liveMessagesDir.appendingPathComponent(name, isDirectory: false)
      let destination = archiveDir.appendingPathComponent(name, isDirectory: false)
      guard fileManager.fileExists(atPath: source.path) else {
        files[name] = ArchiveSnapFile(
          present: false,
          size: nil,
          mtime: nil,
          sourceMtime: nil,
          archiveMtime: nil
        )
        continue
      }

      let sourceMtime = fileMtime(source)
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      switch ArchiveCloner.clone(from: source, to: destination) {
      case .cloned:
        break
      case .unsupported:
        try fileManager.copyItem(at: source, to: destination)
      case .failed(let err):
        throw NSError(
          domain: NSPOSIXErrorDomain,
          code: Int(err),
          userInfo: [NSLocalizedDescriptionKey: "clonefile(\(name)) failed: errno=\(err)"]
        )
      }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
      let archiveMtime = fileMtime(destination)

      files[name] = ArchiveSnapFile(
        present: true,
        size: fileSize(destination),
        mtime: archiveMtime,
        sourceMtime: sourceMtime,
        archiveMtime: archiveMtime
      )
    }

    return files
  }

  private func runRecovery(event: RetractionDetected, archiveDir: URL) -> RecoveryRun {
    let startedAt = Date()
    let recoveryURL = archiveDir.appendingPathComponent("recovery.json", isDirectory: false)
    let stderrURL = archiveDir.appendingPathComponent("recovery.stderr.txt", isDirectory: false)
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = recoverScriptURL
    process.arguments = [
      "--handle", event.handle,
      "--rowid", String(event.rowid),
      "--json",
      "--work", archiveDir.path
    ]
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      let diagnostic = recoveryDiagnosticJSON(exitCode: nil, error: error.localizedDescription)
      try? diagnostic.write(to: recoveryURL, options: .atomic)
      return RecoveryRun(
        manifest: ArchiveRecovery(
          startedAt: isoString(startedAt),
          finishedAt: isoString(Date()),
          exitCode: nil,
          recovered: false,
          error: error.localizedDescription,
          failureCategory: .scriptError
        )
      )
    }

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    try? stderrData.write(to: stderrURL, options: .atomic)

    let outputData: Data
    if stdoutData.isEmpty {
      outputData = recoveryDiagnosticJSON(
        exitCode: Int(process.terminationStatus),
        error: String(data: stderrData, encoding: .utf8) ?? "recover.sh produced no JSON"
      )
    } else {
      outputData = stdoutData
    }
    try? outputData.write(to: recoveryURL, options: .atomic)

    let recovered = recoveryJSONHasText(outputData)
    let failureCategory = recovered ? nil : recoveryJSONFailureCategory(outputData)
    return RecoveryRun(
      manifest: ArchiveRecovery(
        startedAt: isoString(startedAt),
        finishedAt: isoString(Date()),
        exitCode: Int(process.terminationStatus),
        recovered: recovered,
        error: process.terminationStatus == 0 ? nil : "recover.sh exited \(process.terminationStatus)",
        failureCategory: failureCategory
      )
    )
  }

  private func writeManifest(_ manifest: ArchiveManifest, to archiveDir: URL) throws {
    let manifestURL = archiveDir.appendingPathComponent("manifest.json", isDirectory: false)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: manifestURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
  }

  private func ensurePrivateDirectory(_ url: URL) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private func fileSize(_ url: URL) -> Int64? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else {
      return nil
    }

    return size.int64Value
  }

  private func fileMtime(_ url: URL) -> String? {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let mtime = attributes[.modificationDate] as? Date
    else {
      return nil
    }

    return isoString(mtime)
  }
}

private struct RecoveryRun {
  let manifest: ArchiveRecovery
}

public struct ArchiveManifest: Codable, Equatable {
  public let detectedAt: String
  public let rowid: Int64
  public let guid: String
  public let handle: String
  public let editedAt: Int64
  public let snapshotStartedAt: String
  public let snapshotFinishedAt: String
  public let snapFiles: [String: ArchiveSnapFile]
  public var recovery: ArchiveRecovery?

  enum CodingKeys: String, CodingKey {
    case detectedAt = "detected_at"
    case rowid
    case guid
    case handle
    case editedAt = "edited_at"
    case snapshotStartedAt = "snapshot_started_at"
    case snapshotFinishedAt = "snapshot_finished_at"
    case snapFiles = "snap_files"
    case recovery
  }

  public init(
    detectedAt: String,
    rowid: Int64,
    guid: String,
    handle: String,
    editedAt: Int64,
    snapshotStartedAt: String,
    snapshotFinishedAt: String,
    snapFiles: [String: ArchiveSnapFile],
    recovery: ArchiveRecovery?
  ) {
    self.detectedAt = detectedAt
    self.rowid = rowid
    self.guid = guid
    self.handle = handle
    self.editedAt = editedAt
    self.snapshotStartedAt = snapshotStartedAt
    self.snapshotFinishedAt = snapshotFinishedAt
    self.snapFiles = snapFiles
    self.recovery = recovery
  }
}

public struct ArchiveSnapFile: Codable, Equatable {
  public let present: Bool
  public let size: Int64?
  public let mtime: String?
  public let sourceMtime: String?
  public let archiveMtime: String?

  enum CodingKeys: String, CodingKey {
    case present
    case size
    case mtime
    case sourceMtime = "source_mtime"
    case archiveMtime = "archive_mtime"
  }

  public init(
    present: Bool,
    size: Int64?,
    mtime: String?,
    sourceMtime: String?,
    archiveMtime: String?
  ) {
    self.present = present
    self.size = size
    self.mtime = mtime
    self.sourceMtime = sourceMtime
    self.archiveMtime = archiveMtime
  }
}

public struct ArchiveRecovery: Codable, Equatable {
  public let startedAt: String
  public let finishedAt: String
  public let exitCode: Int?
  public let recovered: Bool
  public let error: String?
  public let failureCategory: RecoveryFailureCategory?

  enum CodingKeys: String, CodingKey {
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case exitCode = "exit_code"
    case recovered
    case error
    case failureCategory = "failure_category"
  }

  public init(
    startedAt: String,
    finishedAt: String,
    exitCode: Int?,
    recovered: Bool,
    error: String?,
    failureCategory: RecoveryFailureCategory? = nil
  ) {
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.exitCode = exitCode
    self.recovered = recovered
    self.error = error
    self.failureCategory = failureCategory
  }
}

private func recoveryJSONHasText(_ data: Data) -> Bool {
  guard
    let object = try? JSONSerialization.jsonObject(with: data),
    let payload = object as? [String: Any],
    let recovered = payload["recovered"] as? [String: Any],
    let text = recovered["text_b64"] as? String
  else {
    return false
  }

  return !text.isEmpty
}

func recoveryJSONFailureCategory(_ data: Data) -> RecoveryFailureCategory? {
  guard
    let object = try? JSONSerialization.jsonObject(with: data),
    let payload = object as? [String: Any],
    let recovered = payload["recovered"] as? [String: Any],
    let raw = recovered["failure_category"] as? String
  else {
    return nil
  }

  return RecoveryFailureCategory(rawValue: raw) ?? .unknown
}

private func recoveryDiagnosticJSON(exitCode: Int?, error: String) -> Data {
  var payload: [String: Any] = [
    "schema_version": 1,
    "recovered": [
      "text_b64": NSNull(),
      "length": NSNull(),
      "source": NSNull(),
      "wal_offset": NSNull(),
      "failure_category": RecoveryFailureCategory.scriptError.rawValue
    ],
    "error": error
  ]
  if let exitCode {
    payload["exit_code"] = exitCode
  }
  return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
}

private func isoString(_ date: Date) -> String {
  ISO8601DateFormatter.archiveISO.string(from: date)
}

private func compactTimestamp(_ date: Date) -> String {
  DateFormatter.archiveName.string(from: date)
}

private extension ISO8601DateFormatter {
  static let archiveISO: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
}

private extension DateFormatter {
  static let archiveName: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
    return formatter
  }()
}

public func defaultMessagesDirURL(home: URL = imuUserHomeDirectory()) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Messages", isDirectory: true)
}

public func defaultRecoverScriptURL() -> URL {
  let fileManager = FileManager.default
  let cwdCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("scripts", isDirectory: true)
    .appendingPathComponent("recover.sh", isDirectory: false)
  if fileManager.fileExists(atPath: cwdCandidate.path) {
    return cwdCandidate
  }

  let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  let installCandidate = executableURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("scripts", isDirectory: true)
    .appendingPathComponent("recover.sh", isDirectory: false)
  if fileManager.fileExists(atPath: installCandidate.path) {
    return installCandidate
  }

  return cwdCandidate
}
