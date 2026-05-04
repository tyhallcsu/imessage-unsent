import AppKit
import IMUMenuBarCore
import SwiftUI

struct HistoryWindow: View {
  @ObservedObject var model: MenuBarModel
  @State private var selectedEntry: ArchiveHistoryEntryDTO?
  @State private var loadedDetail: RecoveryDetail?
  @State private var loadError: String?
  @State private var showingCompactAllConfirmation = false
  @State private var compactAllStatus: String?

  @StateObject private var archiveStats = ArchiveStatsProviderObservable()

  private let detailLoader: RecoveryDetailLoading = FileSystemRecoveryDetailLoader()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      summaryBar
      Divider()
      content
    }
    .frame(minWidth: 520, minHeight: 380)
    .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search by name or handle")
    .onAppear {
      model.refresh()
      archiveStats.invalidateAll()
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
    .alert("Compact all archives?", isPresented: $showingCompactAllConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Compact \(compactCandidateCount)", role: .destructive) {
        compactAll()
      }
    } message: {
      Text("This drops the chat.db snapshot files from \(compactCandidateCount) archives but keeps the recovered text + metadata. The action cannot be undone — recover.sh can no longer be re-run against compacted archives.")
    }
  }

  private var compactCandidateCount: Int {
    model.recentEntries.filter { !$0.isCompacted }.count
  }

  private var header: some View {
    HStack {
      Text("Recovered Messages")
        .font(.headline)
      Spacer()
      Button {
        showingCompactAllConfirmation = true
      } label: {
        Label("Compact all", systemImage: "archivebox")
      }
      .disabled(compactCandidateCount == 0)
      .help(compactCandidateCount == 0
            ? "Nothing to compact — every archive is already compacted."
            : "Drop snapshot files from \(compactCandidateCount) archives; keep recovered text.")
      Button {
        model.refresh()
        archiveStats.invalidateAll()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh from daemon + recompute archive sizes")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  /// Storage stats summary bar between header and list. Surfaces total bytes
  /// + recovered/compacted/failed counts so users have a glance-level view of
  /// disk usage and recovery health.
  @ViewBuilder
  private var summaryBar: some View {
    let entries = model.recentEntries
    let aggregate = archiveStats.provider.aggregate(forArchiveIds: entries.map { $0.id })
    let recovered = entries.filter { $0.recovered }.count
    let compacted = entries.filter { $0.isCompacted }.count
    let notRecoverable = entries.filter { !$0.recovered }.count

    HStack(spacing: 16) {
      summaryItem(label: "Total", value: "\(entries.count)")
      summaryItem(label: "Disk", value: aggregate.humanSize)
      if recovered > 0 { summaryItem(label: "Recovered", value: "\(recovered)") }
      if compacted > 0 { summaryItem(label: "Compacted", value: "\(compacted)") }
      if notRecoverable > 0 { summaryItem(label: "Not recoverable", value: "\(notRecoverable)") }
      Spacer()
      if let status = compactAllStatus {
        Label(status, systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  private func summaryItem(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value).font(.callout).fontWeight(.semibold).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
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
          avatarImageData: model.contactsResolver.avatarImageData(forHandle: entry.handle),
          archiveStats: archiveStats.provider.stats(forArchiveId: entry.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
          openDetail(for: entry)
        }
      }
      .listStyle(.inset)
    }
  }

  private func compactAll() {
    let targets = model.recentEntries.filter { !$0.isCompacted }
    var ok = 0
    var failed = 0
    var bytesReclaimed: Int64 = 0
    for entry in targets {
      let result = model.compact(id: entry.id)
      if result.ok {
        ok += 1
        bytesReclaimed += result.bytesReclaimed
        archiveStats.provider.invalidate(archiveId: entry.id)
      } else {
        failed += 1
      }
    }
    archiveStats.objectWillChange.send()
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    let humanReclaimed = formatter.string(fromByteCount: bytesReclaimed)
    if failed == 0 {
      compactAllStatus = "Compacted \(ok) — reclaimed \(humanReclaimed)"
    } else {
      compactAllStatus = "Compacted \(ok), failed \(failed) — reclaimed \(humanReclaimed)"
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      compactAllStatus = nil
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
