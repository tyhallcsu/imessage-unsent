import Foundation

public struct WatchStatus: Codable, Equatable {
  public var status: String
  public var watching: Bool
  public var version: String
  public var socketPath: String
  public var archiveCount: Int
}

public struct ArchiveSummary: Codable, Identifiable, Equatable {
  public var id: String
  public var rowid: Int64?
  public var handle: String?
  public var guid: String?
  public var detectedAt: Date?
  public var recovered: Bool
  public var preview: String?
  public var archiveDir: String
}

public struct ArchiveListResponse: Codable, Equatable {
  public var page: Int
  public var limit: Int
  public var total: Int
  public var archives: [ArchiveSummary]
}

public struct RecoveryDetail: Codable, Equatable {
  public struct Candidate: Codable, Equatable {
    public var rowid: Int64?
    public var guid: String?
    public var sentAt: String?
    public var editedAt: String?
    public var msiOtrLe: Int?

    enum CodingKeys: String, CodingKey {
      case rowid
      case guid
      case sentAt = "sent_at"
      case editedAt = "edited_at"
      case msiOtrLe = "msi_otr_le"
    }
  }

  public struct Recovered: Codable, Equatable {
    public var textB64: String?
    public var length: Int?
    public var source: String?
    public var walOffset: Int?

    enum CodingKeys: String, CodingKey {
      case textB64 = "text_b64"
      case length
      case source
      case walOffset = "wal_offset"
    }
  }

  public var schemaVersion: Int
  public var ranAt: String?
  public var handle: String?
  public var chatRowid: Int64?
  public var candidate: Candidate
  public var recovered: Recovered

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case ranAt = "ran_at"
    case handle
    case chatRowid = "chat_rowid"
    case candidate
    case recovered
  }

  public var recoveredText: String? {
    guard let textB64 = recovered.textB64,
          let data = Data(base64Encoded: textB64) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}

public enum DaemonHealth: Equatable {
  case down
  case idle
  case watching
  case busy

  public var displayText: String {
    switch self {
    case .down: "daemon down"
    case .idle: "idle"
    case .watching: "watching"
    case .busy: "recovering"
    }
  }
}
