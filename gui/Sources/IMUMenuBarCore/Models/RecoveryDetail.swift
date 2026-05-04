import Foundation

public struct RecoveryDetail: Equatable {
  public let id: String
  public let handle: String
  public let rowid: Int64
  public let guid: String
  public let detectedAt: String
  public let editedAt: Int64?
  public let recovered: Bool
  public let recoveredText: String?
  public let recoveryError: String?
  public let archivePath: String
  public let snapshotFiles: [String]
  public let failureCategory: RecoveryFailureCategory?

  public init(
    id: String,
    handle: String,
    rowid: Int64,
    guid: String,
    detectedAt: String,
    editedAt: Int64?,
    recovered: Bool,
    recoveredText: String?,
    recoveryError: String?,
    archivePath: String,
    snapshotFiles: [String],
    failureCategory: RecoveryFailureCategory? = nil
  ) {
    self.id = id
    self.handle = handle
    self.rowid = rowid
    self.guid = guid
    self.detectedAt = detectedAt
    self.editedAt = editedAt
    self.recovered = recovered
    self.recoveredText = recoveredText
    self.recoveryError = recoveryError
    self.archivePath = archivePath
    self.snapshotFiles = snapshotFiles
    self.failureCategory = failureCategory
  }
}
