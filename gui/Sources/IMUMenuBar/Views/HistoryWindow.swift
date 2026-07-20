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

  /// Archive id requested via `imu://history/<id>` deep link. Set by
  /// `IMUMenuBarApp` via the `pendingArchiveId` shared box; on appear we
  /// pop it and open the matching detail sheet.
  @ObservedObject var pendingDeepLink: PendingDeepLink

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
      handlePendingDeepLinkIfAny()
    }
    .onChange(of: pendingDeepLink.archiveId) { _ in
      handlePendingDeepLinkIfAny()
    }
    .onChange(of: model.recentEntries) { _ in
      // Deep link may have arrived before `refresh()` populated the entries;
      // re-try when the list lands.
      handlePendingDeepLinkIfAny()
    }
    .sheet(item: $selectedEntry, onDismiss: {
      loadedDetail = nil
      loadError = nil
      model.clearActionError()
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
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var content: some View {
    let entries = model.filteredEntries
    if entries.isEmpty {
      emptyState
    } else {
      List(entries, id: \.id) { entry in
        // Button (not onTapGesture) so rows are keyboard-activatable and
        // VoiceOver exposes them as actionable elements.
        Button {
          openDetail(for: entry)
        } label: {
          RecoveryRowView(
            entry: entry,
            displayName: model.contactsResolver.displayName(forHandle: entry.handle),
            avatarImageData: model.contactsResolver.avatarImageData(forHandle: entry.handle),
            archiveStats: archiveStats.provider.stats(forArchiveId: entry.id)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        Button("Run Health Check…") {
          if let url = URL(string: "imu://doctor") {
            NSWorkspace.shared.open(url)
          }
        }
        .padding(.top, 4)
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

  /// If `pendingDeepLink.archiveId` is set, find the matching entry in
  /// `model.recentEntries` and open its detail. Clears the pending id so the
  /// same link doesn't re-fire on the next state change.
  private func handlePendingDeepLinkIfAny() {
    guard let id = pendingDeepLink.archiveId else { return }
    guard let entry = model.recentEntries.first(where: { $0.id == id }) else {
      // Entry isn't loaded yet (deep link may have arrived before refresh()
      // populated the list). Leave the id pending so onChange(recentEntries)
      // can retry when the data lands.
      return
    }
    pendingDeepLink.archiveId = nil
    openDetail(for: entry)
  }
}

/// Shared mailbox so external triggers (notification clicks, deep links) can
/// hand a target archive id to the History window without taking a hard
/// dependency on its lifecycle.
@MainActor
public final class PendingDeepLink: ObservableObject {
  @Published public var archiveId: String?

  public init() {}
}
