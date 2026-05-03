import Foundation

public struct ArchiveHistoryEntry: Codable, Equatable {
  public let id: String
  public let detectedAt: String
  public let handle: String
  public let rowid: Int64
  public let recovered: Bool
  public let text: String?
  public let error: String?
  public let archivePath: String

  enum CodingKeys: String, CodingKey {
    case id
    case detectedAt = "detected_at"
    case handle
    case rowid
    case recovered
    case text
    case error
    case archivePath = "archive_path"
  }

  public init(
    id: String,
    detectedAt: String,
    handle: String,
    rowid: Int64,
    recovered: Bool,
    text: String?,
    error: String?,
    archivePath: String
  ) {
    self.id = id
    self.detectedAt = detectedAt
    self.handle = handle
    self.rowid = rowid
    self.recovered = recovered
    self.text = text
    self.error = error
    self.archivePath = archivePath
  }
}

public struct ArchiveHistoryReader {
  public let archivesDir: URL
  private let fileManager: FileManager
  private let onSkip: ((String, String) -> Void)?

  public init(
    archivesDir: URL,
    fileManager: FileManager = .default,
    onSkip: ((String, String) -> Void)? = nil
  ) {
    self.archivesDir = archivesDir
    self.fileManager = fileManager
    self.onSkip = onSkip
  }

  public func recent(limit: Int) -> [ArchiveHistoryEntry] {
    guard limit > 0, fileManager.fileExists(atPath: archivesDir.path) else {
      return []
    }

    let contents = (try? fileManager.contentsOfDirectory(
      at: archivesDir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    let candidates = contents
      .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          && Self.archiveDirectoryNamePattern.firstMatch(
            in: url.lastPathComponent,
            range: NSRange(location: 0, length: url.lastPathComponent.utf16.count)
          ) != nil
      }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }

    var entries: [ArchiveHistoryEntry] = []
    for url in candidates {
      if entries.count >= limit {
        break
      }
      switch parseEntry(at: url) {
      case let .success(entry):
        entries.append(entry)
      case let .failure(reason):
        onSkip?(url.lastPathComponent, reason)
      }
    }
    return entries
  }

  private enum ParseResult {
    case success(ArchiveHistoryEntry)
    case failure(String)
  }

  private func parseEntry(at archiveDir: URL) -> ParseResult {
    let manifestURL = archiveDir.appendingPathComponent("manifest.json", isDirectory: false)
    let recoveryURL = archiveDir.appendingPathComponent("recovery.json", isDirectory: false)

    guard let manifestData = try? Data(contentsOf: manifestURL) else {
      return .failure("manifest.json missing or unreadable")
    }
    let manifest: ManifestDTO
    do {
      manifest = try JSONDecoder().decode(ManifestDTO.self, from: manifestData)
    } catch {
      return .failure("manifest.json decode failed: \(error.localizedDescription)")
    }

    var recovered = manifest.recovery?.recovered ?? false
    var text: String?
    var error = manifest.recovery?.error

    if let recoveryData = try? Data(contentsOf: recoveryURL) {
      if let payload = try? JSONDecoder().decode(RecoveryFileDTO.self, from: recoveryData) {
        if
          let textB64 = payload.recovered?.textB64,
          let data = Data(base64Encoded: textB64),
          let decoded = String(data: data, encoding: .utf8),
          !decoded.isEmpty
        {
          text = decoded
          recovered = true
        }
        if let payloadError = payload.error, !payloadError.isEmpty {
          error = payloadError
        }
      }
    }

    return .success(
      ArchiveHistoryEntry(
        id: archiveDir.lastPathComponent,
        detectedAt: manifest.detectedAt,
        handle: manifest.handle,
        rowid: manifest.rowid,
        recovered: recovered,
        text: text,
        error: error,
        archivePath: archiveDir.path
      )
    )
  }

  static let archiveDirectoryNamePattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{6}Z-\\d+$")
  }()
}

private struct ManifestDTO: Decodable {
  let detectedAt: String
  let rowid: Int64
  let handle: String
  let recovery: RecoveryDTO?

  enum CodingKeys: String, CodingKey {
    case detectedAt = "detected_at"
    case rowid
    case handle
    case recovery
  }
}

private struct RecoveryDTO: Decodable {
  let recovered: Bool
  let error: String?
}

private struct RecoveryFileDTO: Decodable {
  let recovered: RecoveredFileDTO?
  let error: String?
}

private struct RecoveredFileDTO: Decodable {
  let textB64: String?

  enum CodingKeys: String, CodingKey {
    case textB64 = "text_b64"
  }
}
