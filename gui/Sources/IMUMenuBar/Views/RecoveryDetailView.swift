import AppKit
import IMUMenuBarCore
import SwiftUI

struct RecoveryDetailView: View {
  @ObservedObject var model: MenuBarModel
  let entry: ArchiveHistoryEntryDTO
  let dismiss: () -> Void

  @StateObject private var retryModel: IPhoneBackupRetryModel
  @State private var currentDetail: RecoveryDetail?
  @State private var currentLoadError: String?

  @State private var showingDeleteConfirmation = false
  @State private var showingCompactConfirmation = false
  @State private var copyConfirmation: String?
  @State private var compactStatus: String?

  init(
    model: MenuBarModel,
    entry: ArchiveHistoryEntryDTO,
    detail: RecoveryDetail?,
    loadError: String?,
    dismiss: @escaping () -> Void,
    retryRunner: IPhoneBackupRetryRunning = IPhoneBackupRetryRunner()
  ) {
    self.model = model
    self.entry = entry
    self.dismiss = dismiss
    _currentDetail = State(initialValue: detail)
    _currentLoadError = State(initialValue: loadError)
    _retryModel = StateObject(wrappedValue: IPhoneBackupRetryModel(runner: retryRunner))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          recoveredTextBlock
          metadataBlock
        }
        .padding(20)
      }
      Divider()
      footer
    }
    .frame(minWidth: 520, minHeight: 420)
    .alert("Delete archive?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        if model.delete(id: entry.id) {
          dismiss()
        }
      }
    } message: {
      Text("This permanently removes the archive directory and its snapshot files. The original chat.db is not touched.")
    }
    .alert("Compact archive?", isPresented: $showingCompactConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Compact", role: .destructive) {
        let result = model.compact(id: entry.id)
        if result.ok {
          let mb = Double(result.bytesReclaimed) / 1_000_000
          compactStatus = String(format: "Compacted — reclaimed %.1f MB", mb)
        } else {
          compactStatus = "Compact failed: \(result.errorMessage ?? "unknown error")"
        }
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 2_500_000_000)
          compactStatus = nil
        }
      }
    } message: {
      Text("This drops the chat.db snapshot files but keeps the recovered text and metadata. The recovered message will still appear in History; the underlying chat.db copy is gone forever.")
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(model.contactsResolver.displayName(forHandle: entry.handle) ?? entry.handle)
            .font(.title3)
            .fontWeight(.semibold)
          if entry.isCompacted {
            Text("Compacted")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.18)))
              .help("Snapshot files dropped to reclaim disk space; recovered text retained.")
          }
        }
        Text(entry.handle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button(role: .cancel) { dismiss() } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  @ViewBuilder
  private var recoveredTextBlock: some View {
    if let text = currentDetail?.recoveredText ?? entry.text, !text.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Recovered text")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
      }
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text(notRecoverableHeader)
          .font(.caption)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
          Text(notRecoverableMessage)
            .textSelection(.enabled)
            .foregroundStyle(.primary)
          if let hint = notRecoverableHint {
            Text(hint)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          if shouldShowIPhoneBackupRetry {
            HStack(alignment: .center, spacing: 10) {
              Button {
                retryFromIPhoneBackup()
              } label: {
                Label("Try iPhone backup", systemImage: "iphone")
              }
              .disabled(retryModel.isRunning || entry.isCompacted)
              .help(entry.isCompacted
                    ? "Retry unavailable after compaction"
                    : "Re-run recover.sh against iPhone backups only.")
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
      }
    }
  }

  private var failureCategory: RecoveryFailureCategory? {
    currentDetail?.failureCategory ?? entry.failureCategory
  }

  private var notRecoverableHeader: String {
    if let category = failureCategory {
      return "Not recoverable — \(category.rawValue)"
    }
    return "Not recoverable"
  }

  private var notRecoverableMessage: String {
    if let category = failureCategory {
      return category.displayMessage
    }
    return currentDetail?.recoveryError ?? entry.error ?? "(no text recovered)"
  }

  private var notRecoverableHint: String? {
    failureCategory?.actionableHint
  }

  private var metadataBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Details")
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        metadataRow("Handle", entry.handle)
        metadataRow("Row ID", String(entry.rowid))
        if let currentDetail {
          metadataRow("GUID", currentDetail.guid)
        }
        metadataRow("Detected at", entry.detectedAt)
        metadataRow("Archive ID", entry.id)
        metadataRow("Archive path", entry.archivePath)
        if let currentDetail, !currentDetail.snapshotFiles.isEmpty {
          metadataRow("Snapshot files", currentDetail.snapshotFiles.joined(separator: ", "))
        }
        if let currentLoadError {
          metadataRow("Load warning", currentLoadError)
        }
      }
      .padding(12)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06)))
    }
  }

  private func metadataRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .leading)
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var footer: some View {
    HStack {
      if let confirmation = copyConfirmation {
        Label(confirmation, systemImage: "checkmark")
          .foregroundStyle(.secondary)
          .font(.caption)
      } else if let status = compactStatus {
        Label(status, systemImage: "archivebox")
          .foregroundStyle(.secondary)
          .font(.caption)
      } else if let statusText = retryModel.statusMessage,
                let statusImage = retryModel.statusSystemImage {
        retryStatusChip(text: statusText, systemImage: statusImage)
      }
      Spacer()
      Button {
        copyRecoveredText()
      } label: {
        Label("Copy text", systemImage: "doc.on.doc")
      }
      .disabled((currentDetail?.recoveredText ?? entry.text)?.isEmpty != false)
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.archivePath, isDirectory: true))
      } label: {
        Label("Open archive", systemImage: "folder")
      }
      Button {
        showingCompactConfirmation = true
      } label: {
        Label("Compact", systemImage: "archivebox")
      }
      .disabled(entry.isCompacted)
      .help(entry.isCompacted ? "Already compacted" : "Drop snapshot files; keep recovered text + manifest.")
      Button(role: .destructive) {
        showingDeleteConfirmation = true
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private func copyRecoveredText() {
    let text = currentDetail?.recoveredText ?? entry.text ?? ""
    guard !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    copyConfirmation = "Copied to clipboard"
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      copyConfirmation = nil
    }
  }

  private var shouldShowIPhoneBackupRetry: Bool {
    !(currentDetail?.recovered ?? entry.recovered)
  }

  private func retryFromIPhoneBackup() {
    let archiveDir = URL(fileURLWithPath: entry.archivePath, isDirectory: true)
    Task { @MainActor in
      if let reloadedDetail = await retryModel.retry(
        archiveDir: archiveDir,
        handle: entry.handle,
        rowid: entry.rowid
      ) {
        currentDetail = reloadedDetail
        currentLoadError = nil
        model.refresh()
      }
    }
  }

  private func retryStatusChip(text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
  }
}
