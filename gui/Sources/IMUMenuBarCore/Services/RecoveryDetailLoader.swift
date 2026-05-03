import Foundation

public enum RecoveryDetailLoaderError: Error, LocalizedError {
  case manifestMissing(URL)
  case manifestDecode(String)

  public var errorDescription: String? {
    switch self {
    case let .manifestMissing(url):
      return "manifest.json missing at \(url.path)"
    case let .manifestDecode(reason):
      return "manifest.json could not be decoded: \(reason)"
    }
  }
}

public protocol RecoveryDetailLoading {
  func load(archiveDir: URL) throws -> RecoveryDetail
}

public struct FileSystemRecoveryDetailLoader: RecoveryDetailLoading {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func load(archiveDir: URL) throws -> RecoveryDetail {
    let manifestURL = archiveDir.appendingPathComponent("manifest.json", isDirectory: false)
    guard let manifestData = try? Data(contentsOf: manifestURL) else {
      throw RecoveryDetailLoaderError.manifestMissing(manifestURL)
    }
    let manifest: ManifestDTO
    do {
      manifest = try JSONDecoder().decode(ManifestDTO.self, from: manifestData)
    } catch {
      throw RecoveryDetailLoaderError.manifestDecode(error.localizedDescription)
    }

    var recovered = manifest.recovery?.recovered ?? false
    var recoveredText: String?
    var recoveryError = manifest.recovery?.error

    let recoveryURL = archiveDir.appendingPathComponent("recovery.json", isDirectory: false)
    if let recoveryData = try? Data(contentsOf: recoveryURL),
       let payload = try? JSONDecoder().decode(RecoveryFileDTO.self, from: recoveryData) {
      if let textB64 = payload.recovered?.textB64,
         let raw = Data(base64Encoded: textB64),
         let decoded = String(data: raw, encoding: .utf8),
         !decoded.isEmpty {
        recoveredText = decoded
        recovered = true
      }
      if let payloadError = payload.error, !payloadError.isEmpty {
        recoveryError = payloadError
      }
    }

    let snapshotFiles = manifest.snapFiles?
      .filter { $0.value.present }
      .keys
      .sorted() ?? []

    return RecoveryDetail(
      id: archiveDir.lastPathComponent,
      handle: manifest.handle,
      rowid: manifest.rowid,
      guid: manifest.guid,
      detectedAt: manifest.detectedAt,
      editedAt: manifest.editedAt,
      recovered: recovered,
      recoveredText: recoveredText,
      recoveryError: recoveryError,
      archivePath: archiveDir.path,
      snapshotFiles: snapshotFiles
    )
  }
}

private struct ManifestDTO: Decodable {
  let detectedAt: String
  let rowid: Int64
  let guid: String
  let handle: String
  let editedAt: Int64?
  let snapFiles: [String: SnapFileDTO]?
  let recovery: ManifestRecoveryDTO?

  enum CodingKeys: String, CodingKey {
    case detectedAt = "detected_at"
    case rowid
    case guid
    case handle
    case editedAt = "edited_at"
    case snapFiles = "snap_files"
    case recovery
  }
}

private struct SnapFileDTO: Decodable {
  let present: Bool
}

private struct ManifestRecoveryDTO: Decodable {
  let recovered: Bool?
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
