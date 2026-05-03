import AppKit
import IMUMenuBarCore
import SwiftUI

struct RecoveryDetailView: View {
  @ObservedObject var model: MenuBarModel
  let entry: ArchiveHistoryEntryDTO
  let detail: RecoveryDetail?
  let loadError: String?
  let dismiss: () -> Void

  @State private var showingDeleteConfirmation = false
  @State private var copyConfirmation: String?

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
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.contactsResolver.displayName(forHandle: entry.handle) ?? entry.handle)
          .font(.title3)
          .fontWeight(.semibold)
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
    if let text = detail?.recoveredText ?? entry.text, !text.isEmpty {
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
        Text("Not recoverable")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(detail?.recoveryError ?? entry.error ?? "(no text recovered)")
          .textSelection(.enabled)
          .foregroundStyle(.primary)
          .padding(12)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
      }
    }
  }

  private var metadataBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Details")
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        metadataRow("Handle", entry.handle)
        metadataRow("Row ID", String(entry.rowid))
        if let detail {
          metadataRow("GUID", detail.guid)
        }
        metadataRow("Detected at", entry.detectedAt)
        metadataRow("Archive ID", entry.id)
        metadataRow("Archive path", entry.archivePath)
        if let detail, !detail.snapshotFiles.isEmpty {
          metadataRow("Snapshot files", detail.snapshotFiles.joined(separator: ", "))
        }
        if let loadError {
          metadataRow("Load warning", loadError)
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
      }
      Spacer()
      Button {
        copyRecoveredText()
      } label: {
        Label("Copy text", systemImage: "doc.on.doc")
      }
      .disabled((detail?.recoveredText ?? entry.text)?.isEmpty != false)
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.archivePath, isDirectory: true))
      } label: {
        Label("Open archive", systemImage: "folder")
      }
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
    let text = detail?.recoveredText ?? entry.text ?? ""
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
}
