import AppKit
import IMUMenuBarCore
import SwiftUI

struct HistoryWindow: View {
  @ObservedObject var model: MenuBarModel
  @State private var selectedEntry: ArchiveHistoryEntryDTO?
  @State private var loadedDetail: RecoveryDetail?
  @State private var loadError: String?

  private let detailLoader: RecoveryDetailLoading = FileSystemRecoveryDetailLoader()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 520, minHeight: 380)
    .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search by name or handle")
    .onAppear {
      model.refresh()
    }
    .sheet(item: $selectedEntry, onDismiss: {
      loadedDetail = nil
      loadError = nil
    }) { entry in
      RecoveryDetailView(
        model: model,
        entry: entry,
        detail: loadedDetail,
        loadError: loadError,
        dismiss: { selectedEntry = nil }
      )
    }
  }

  private var header: some View {
    HStack {
      Text("Recovered Messages")
        .font(.headline)
      Spacer()
      Button {
        model.refresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh from daemon")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var content: some View {
    let entries = model.filteredEntries
    if entries.isEmpty {
      emptyState
    } else {
      List(entries, id: \.id) { entry in
        RecoveryRowView(
          entry: entry,
          displayName: model.contactsResolver.displayName(forHandle: entry.handle),
          avatarImageData: model.contactsResolver.avatarImageData(forHandle: entry.handle)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          openDetail(for: entry)
        }
      }
      .listStyle(.inset)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: model.recentEntries.isEmpty ? "tray" : "magnifyingglass")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)
      Text(emptyStateTitle)
        .foregroundStyle(.secondary)
      if model.status == .down {
        Text("Start imu-watcher to begin watching chat.db.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else if model.recentEntries.isEmpty {
        Text("Once someone unsends a message you'll see it here.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        Text("No recoveries match \"\(model.searchText)\".")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateTitle: String {
    if model.status == .down { return "Daemon is not running" }
    if model.recentEntries.isEmpty { return "No recoveries yet" }
    return "No matches"
  }

  private func openDetail(for entry: ArchiveHistoryEntryDTO) {
    do {
      loadedDetail = try detailLoader.load(archiveDir: URL(fileURLWithPath: entry.archivePath, isDirectory: true))
      loadError = nil
    } catch {
      loadedDetail = nil
      loadError = error.localizedDescription
    }
    selectedEntry = entry
  }
}
