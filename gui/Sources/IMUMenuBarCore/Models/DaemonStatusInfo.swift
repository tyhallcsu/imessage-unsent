import Foundation

public struct DaemonStatusInfo: Codable, Equatable {
  public let state: String
  public let version: String
  public let startedAt: String
  public let uptimeSeconds: Int
  public let lastWalChangeAt: String?
  public let lastWalSize: Int64
  public let recoveryCount: Int
  public let lastError: String?
  public let dataDir: String
  public let notificationsShow: Bool
  /// Result of the daemon's most recent `open(2)` against `chat.db`. Distinct
  /// from `lastError` because a stat-only success can coexist with an
  /// open-failure under TCC (see issue #59). Nil means the daemon has not yet
  /// probed (or the daemon is older than the field landing).
  public let chatDBReadable: Bool?
  public let chatDBProbedAt: String?

  enum CodingKeys: String, CodingKey {
    case state
    case version
    case startedAt = "started_at"
    case uptimeSeconds = "uptime_seconds"
    case lastWalChangeAt = "last_wal_change_at"
    case lastWalSize = "last_wal_size"
    case recoveryCount = "recovery_count"
    case lastError = "last_error"
    case dataDir = "data_dir"
    case notificationsShow = "notifications_show"
    case chatDBReadable = "chat_db_readable"
    case chatDBProbedAt = "chat_db_probed_at"
  }

  public init(
    state: String,
    version: String,
    startedAt: String,
    uptimeSeconds: Int,
    lastWalChangeAt: String?,
    lastWalSize: Int64,
    recoveryCount: Int,
    lastError: String?,
    dataDir: String,
    notificationsShow: Bool,
    chatDBReadable: Bool? = nil,
    chatDBProbedAt: String? = nil
  ) {
    self.state = state
    self.version = version
    self.startedAt = startedAt
    self.uptimeSeconds = uptimeSeconds
    self.lastWalChangeAt = lastWalChangeAt
    self.lastWalSize = lastWalSize
    self.recoveryCount = recoveryCount
    self.lastError = lastError
    self.dataDir = dataDir
    self.notificationsShow = notificationsShow
    self.chatDBReadable = chatDBReadable
    self.chatDBProbedAt = chatDBProbedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    state = try container.decode(String.self, forKey: .state)
    version = try container.decode(String.self, forKey: .version)
    startedAt = try container.decode(String.self, forKey: .startedAt)
    uptimeSeconds = try container.decode(Int.self, forKey: .uptimeSeconds)
    lastWalChangeAt = try container.decodeIfPresent(String.self, forKey: .lastWalChangeAt)
    lastWalSize = try container.decode(Int64.self, forKey: .lastWalSize)
    recoveryCount = try container.decode(Int.self, forKey: .recoveryCount)
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    dataDir = try container.decode(String.self, forKey: .dataDir)
    notificationsShow = try container.decode(Bool.self, forKey: .notificationsShow)
    chatDBReadable = try container.decodeIfPresent(Bool.self, forKey: .chatDBReadable)
    chatDBProbedAt = try container.decodeIfPresent(String.self, forKey: .chatDBProbedAt)
  }
}

public struct ArchiveHistoryEntryDTO: Codable, Equatable, Identifiable {
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
