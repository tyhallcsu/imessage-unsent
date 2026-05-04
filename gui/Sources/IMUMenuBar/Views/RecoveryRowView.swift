import AppKit
import IMUMenuBarCore
import SwiftUI

struct RecoveryRowView: View {
  let entry: ArchiveHistoryEntryDTO
  let displayName: String?
  let avatarImageData: Data?
  let archiveStats: ArchiveStatsProvider.Stats?

  init(
    entry: ArchiveHistoryEntryDTO,
    displayName: String?,
    avatarImageData: Data?,
    archiveStats: ArchiveStatsProvider.Stats? = nil
  ) {
    self.entry = entry
    self.displayName = displayName
    self.avatarImageData = avatarImageData
    self.archiveStats = archiveStats
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      avatar
        .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: 4) {
        Text(titleLine)
          .lineLimit(2)
          .truncationMode(.tail)
          .font(.body)
        HStack(spacing: 6) {
          Text(displayName ?? entry.handle)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("·")
            .foregroundStyle(.tertiary)
          Text(Self.relativeTimeString(from: entry.detectedAt))
            .font(.caption)
            .foregroundStyle(.secondary)
          if let archiveStats {
            Text("·")
              .foregroundStyle(.tertiary)
            Text(archiveStats.humanSize)
              .font(.caption)
              .foregroundStyle(.secondary)
              .help("Archive size on disk: \(archiveStats.bytes) bytes across \(archiveStats.fileCount) files")
          }
          if entry.isCompacted {
            Text("·")
              .foregroundStyle(.tertiary)
            Text("Compacted")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.18)))
              .help("Snapshot files dropped to reclaim disk space; recovered text retained.")
          }
        }
      }

      Spacer()
      statusBadge
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var titleLine: String {
    if let text = entry.text, !text.isEmpty {
      return text
    }
    if let error = entry.error, !error.isEmpty {
      return error
    }
    return "(text not recoverable)"
  }

  @ViewBuilder
  private var avatar: some View {
    if let data = avatarImageData, let nsImage = NSImage(data: data) {
      Image(nsImage: nsImage)
        .resizable()
        .scaledToFill()
        .clipShape(Circle())
    } else {
      ZStack {
        Circle().fill(Color.accentColor.opacity(0.18))
        Text(Self.initials(displayName: displayName, handle: entry.handle))
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    if entry.recovered {
      Label("Recovered", systemImage: "checkmark.circle.fill")
        .labelStyle(.iconOnly)
        .foregroundStyle(.green)
        .help("Recovered")
    } else {
      Label("Not recoverable", systemImage: "exclamationmark.triangle.fill")
        .labelStyle(.iconOnly)
        .foregroundStyle(.orange)
        .help(badgeTooltip)
    }
  }

  private var badgeTooltip: String {
    if let category = entry.failureCategory {
      if let hint = category.actionableHint {
        return "\(category.displayMessage)\n\n\(hint)"
      }
      return category.displayMessage
    }
    return entry.error ?? "Not recoverable"
  }

  static func initials(displayName: String?, handle: String) -> String {
    if let name = displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      let parts = name.split(separator: " ").prefix(2)
      let chars = parts.compactMap { $0.first.map { String($0) } }
      if !chars.isEmpty {
        return chars.joined().uppercased()
      }
    }
    let trimmed = handle.trimmingCharacters(in: CharacterSet(charactersIn: "+ "))
    if let last = trimmed.suffix(2).first {
      return String(last) + String(trimmed.last ?? Character("?"))
    }
    return "??"
  }

  static func relativeTimeString(from iso: String, now: Date = Date()) -> String {
    guard let date = Self.isoFormatter.date(from: iso) else { return iso }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
  }()
}
