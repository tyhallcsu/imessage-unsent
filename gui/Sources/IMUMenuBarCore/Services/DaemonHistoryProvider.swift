import Foundation

public struct DaemonHistoryProvider: RecoveryHistoryProviding {
  private let client: DaemonControlClienting
  private let now: () -> Date

  public init(client: DaemonControlClienting, now: @escaping () -> Date = Date.init) {
    self.client = client
    self.now = now
  }

  public func recentRecoveries(limit: Int) -> [RecoverySummary] {
    client.recent(limit: limit).map { mapEntry($0) }
  }

  func mapEntry(_ entry: ArchiveHistoryEntryDTO) -> RecoverySummary {
    let title = entry.text?.isEmpty == false
      ? entry.text!
      : (entry.error.flatMap { $0.isEmpty ? nil : $0 } ?? "(text not recoverable)")
    let detail = "\(entry.handle) · \(formatRelative(entry.detectedAt))"
    return RecoverySummary(
      title: title,
      detail: detail,
      archiveURL: URL(fileURLWithPath: entry.archivePath, isDirectory: true)
    )
  }

  private func formatRelative(_ iso: String) -> String {
    guard let date = Self.isoFormatter.date(from: iso) else {
      return iso
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now())
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
}
