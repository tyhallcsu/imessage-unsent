import Foundation

/// Severity of a single App Doctor row. `Comparable` puts `.fail` first so
/// the worst news rises to the top of the list and the diagnostics report.
public enum HealthSeverity: String, Sendable, Equatable, Comparable {
  case fail
  case warn
  case pass
  case info

  private var sortRank: Int {
    switch self {
    case .fail: return 0
    case .warn: return 1
    case .pass: return 2
    case .info: return 3
    }
  }

  public static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool {
    lhs.sortRank < rhs.sortRank
  }
}

/// Coarse grouping for App Doctor rows. Used for sorting and could later drive
/// section headers in the UI.
public enum HealthCategory: String, Sendable, Equatable, Comparable {
  case daemon
  case permissions
  case storage
  case config
  case logs

  private var sortRank: Int {
    switch self {
    case .daemon: return 0
    case .permissions: return 1
    case .storage: return 2
    case .config: return 3
    case .logs: return 4
    }
  }

  public static func < (lhs: HealthCategory, rhs: HealthCategory) -> Bool {
    lhs.sortRank < rhs.sortRank
  }
}

/// A single row in the App Doctor window and the diagnostics report.
public struct HealthCheck: Identifiable, Equatable, Sendable {
  public let id: String
  public let category: HealthCategory
  public let order: Int
  public let severity: HealthSeverity
  public let title: String
  public let summary: String
  public let detail: String?
  public let remediation: String?
  public let remediationURL: URL?

  public init(
    id: String,
    category: HealthCategory,
    order: Int,
    severity: HealthSeverity,
    title: String,
    summary: String,
    detail: String? = nil,
    remediation: String? = nil,
    remediationURL: URL? = nil
  ) {
    self.id = id
    self.category = category
    self.order = order
    self.severity = severity
    self.title = title
    self.summary = summary
    self.detail = detail
    self.remediation = remediation
    self.remediationURL = remediationURL
  }
}

public extension Array where Element == HealthCheck {
  /// Sort: severity (FAIL → WARN → PASS → INFO) → category → order.
  func sortedForDisplay() -> [HealthCheck] {
    sorted { lhs, rhs in
      if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
      if lhs.category != rhs.category { return lhs.category < rhs.category }
      return lhs.order < rhs.order
    }
  }
}
