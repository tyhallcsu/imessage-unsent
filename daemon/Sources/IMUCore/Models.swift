import Foundation

public let imuVersion = "0.1.0"

public struct WatchStatus: Codable, Equatable {
  public var status: String
  public var watching: Bool
  public var version: String
  public var socketPath: String
  public var archiveCount: Int

  public init(status: String, watching: Bool, version: String = imuVersion, socketPath: String, archiveCount: Int) {
    self.status = status
    self.watching = watching
    self.version = version
    self.socketPath = socketPath
    self.archiveCount = archiveCount
  }
}

public struct RetractionEvent: Codable, Equatable {
  public var rowid: Int64
  public var guid: String
  public var handle: String
  public var editedAt: Int64

  public init(rowid: Int64, guid: String, handle: String, editedAt: Int64) {
    self.rowid = rowid
    self.guid = guid
    self.handle = handle
    self.editedAt = editedAt
  }
}

public struct RecoveryComplete: Codable, Equatable {
  public var archiveID: String
  public var archiveDir: String
  public var recovered: Bool
  public var reason: String?

  public init(archiveID: String, archiveDir: String, recovered: Bool, reason: String? = nil) {
    self.archiveID = archiveID
    self.archiveDir = archiveDir
    self.recovered = recovered
    self.reason = reason
  }
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

  public init(
    id: String,
    rowid: Int64?,
    handle: String?,
    guid: String?,
    detectedAt: Date?,
    recovered: Bool,
    preview: String?,
    archiveDir: String
  ) {
    self.id = id
    self.rowid = rowid
    self.handle = handle
    self.guid = guid
    self.detectedAt = detectedAt
    self.recovered = recovered
    self.preview = preview
    self.archiveDir = archiveDir
  }
}

public struct ArchiveListResponse: Codable, Equatable {
  public var page: Int
  public var limit: Int
  public var total: Int
  public var archives: [ArchiveSummary]
}

public struct Manifest: Codable, Equatable {
  public struct SnapshotFile: Codable, Equatable {
    public var size: UInt64
    public var mtime: Date
  }

  public var detectedAt: Date
  public var rowid: Int64
  public var guid: String
  public var handle: String
  public var snapshotStartedAt: Date
  public var snapshotFinishedAt: Date
  public var snapFiles: [String: SnapshotFile]
}
