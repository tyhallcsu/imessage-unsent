import Foundation

public enum DaemonStatus: Equatable {
  case idle
  case watching
  case detecting
  case down

  public var menuTitle: String {
    switch self {
    case .idle:
      return "Idle"
    case .watching:
      return "Watching"
    case .detecting:
      return "Recovering"
    case .down:
      return "Daemon Down"
    }
  }
}

public struct RecoverySummary: Identifiable, Equatable {
  public let id: UUID
  public let title: String
  public let detail: String
  public let archiveURL: URL

  public init(id: UUID = UUID(), title: String, detail: String, archiveURL: URL) {
    self.id = id
    self.title = title
    self.detail = detail
    self.archiveURL = archiveURL
  }
}
