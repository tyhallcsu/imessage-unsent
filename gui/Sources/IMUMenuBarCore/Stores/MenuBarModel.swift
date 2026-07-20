import Foundation

public protocol RecoveryHistoryProviding {
  func recentRecoveries(limit: Int) -> [RecoverySummary]
}

public struct EmptyRecoveryHistoryProvider: RecoveryHistoryProviding {
  public init() {}

  public func recentRecoveries(limit _: Int) -> [RecoverySummary] {
    []
  }
}

public struct NoArchiveDeleter: ArchiveDeleting {
  public init() {}
  public func deleteArchive(id _: String) -> Bool { false }
}

public protocol ArchiveCompacting {
  func compactArchive(id: String) -> CompactResult
}

public struct NoArchiveCompactor: ArchiveCompacting {
  public init() {}
  public func compactArchive(id _: String) -> CompactResult {
    CompactResult(ok: false, errorMessage: "no compactor configured")
  }
}

public struct DaemonArchiveCompactor: ArchiveCompacting {
  private let client: DaemonControlClienting

  public init(client: DaemonControlClienting) {
    self.client = client
  }

  public func compactArchive(id: String) -> CompactResult {
    client.compact(id: id)
  }
}

@MainActor
public final class MenuBarModel: ObservableObject {
  @Published public private(set) var status: DaemonStatus = .idle
  @Published public private(set) var statusInfo: DaemonStatusInfo?
  @Published public private(set) var recentRecoveries: [RecoverySummary] = []
  @Published public private(set) var recentEntries: [ArchiveHistoryEntryDTO] = []
  @Published public var searchText: String = ""

  /// Most recent archive delete/compact failure, kept until the next
  /// successful action or an explicit `clearActionError()`. The 2 s refresh
  /// timer must NOT clear it — the user needs time to read the failure.
  @Published public private(set) var lastActionError: String?

  public let contactsResolver: ContactsResolving

  private let pinger: DaemonPinging
  private let historyProvider: RecoveryHistoryProviding
  private let entryProvider: RecoveryEntryProviding
  private let archiveDeleter: ArchiveDeleting
  private let archiveCompactor: ArchiveCompacting
  private let statusProvider: (() -> DaemonStatusInfo?)?
  private var timer: Timer?

  public init(
    pinger: DaemonPinging,
    historyProvider: RecoveryHistoryProviding = EmptyRecoveryHistoryProvider(),
    entryProvider: RecoveryEntryProviding = EmptyRecoveryEntryProvider(),
    archiveDeleter: ArchiveDeleting = NoArchiveDeleter(),
    archiveCompactor: ArchiveCompacting = NoArchiveCompactor(),
    contactsResolver: ContactsResolving = NoContactsResolver(),
    statusProvider: (() -> DaemonStatusInfo?)? = nil
  ) {
    self.pinger = pinger
    self.historyProvider = historyProvider
    self.entryProvider = entryProvider
    self.archiveDeleter = archiveDeleter
    self.archiveCompactor = archiveCompactor
    self.contactsResolver = contactsResolver
    self.statusProvider = statusProvider
  }

  public convenience init() {
    let client = DaemonControlClient()
    self.init(
      pinger: client,
      historyProvider: DaemonHistoryProvider(client: client),
      entryProvider: DaemonRecoveryEntryProvider(client: client),
      archiveDeleter: DaemonArchiveDeleter(client: client),
      archiveCompactor: DaemonArchiveCompactor(client: client),
      contactsResolver: CNContactsResolver(),
      statusProvider: { client.status() }
    )
  }

  deinit {
    timer?.invalidate()
  }

  public func start() {
    refresh()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
  }

  public func refresh() {
    let info = statusProvider?()
    statusInfo = info
    if let info {
      status = mapState(info.state)
    } else {
      status = pinger.ping() ? .watching : .down
    }
    recentRecoveries = Array(historyProvider.recentRecoveries(limit: 5).prefix(5))
    recentEntries = entryProvider.recentEntries(limit: 50)
  }

  /// Filtered slice of `recentEntries` honoring `searchText`. The match is
  /// case-insensitive on the handle OR (when Contacts is available) on the
  /// resolved contact name.
  public var filteredEntries: [ArchiveHistoryEntryDTO] {
    let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if needle.isEmpty { return recentEntries }
    return recentEntries.filter { entry in
      if entry.handle.lowercased().contains(needle) { return true }
      if let name = contactsResolver.displayName(forHandle: entry.handle),
         name.lowercased().contains(needle) {
        return true
      }
      return false
    }
  }

  /// True when the daemon's own open(2) probe reports chat.db is unreadable —
  /// the Full Disk Access grant was lost (typical after a rebuild changes the
  /// binary's code identity). nil/absent probe data is NOT treated as denied.
  public var fullDiskAccessDenied: Bool {
    statusInfo?.chatDBReadable == false
  }

  /// True when the primary surfaces (menu bar icon, dropdown) should show an
  /// attention marker: recovery is silently broken while the app looks alive.
  public var needsAttention: Bool {
    status == .down || fullDiskAccessDenied
  }

  /// Removes the archive via the daemon and refreshes local state on success.
  /// Returns whether the daemon reported success.
  @discardableResult
  public func delete(id: String) -> Bool {
    guard archiveDeleter.deleteArchive(id: id) else {
      lastActionError = "Delete failed — the daemon refused or the archive is already gone."
      return false
    }
    lastActionError = nil
    refresh()
    return true
  }

  /// Compacts the archive via the daemon — drops chat.db family, keeps
  /// recovered text + manifest. Returns the daemon's `CompactResult`.
  @discardableResult
  public func compact(id: String) -> CompactResult {
    let result = archiveCompactor.compactArchive(id: id)
    if result.ok {
      lastActionError = nil
      refresh()
    } else {
      lastActionError = result.errorMessage ?? "Compact failed."
    }
    return result
  }

  public func clearActionError() {
    lastActionError = nil
  }

  private func mapState(_ raw: String) -> DaemonStatus {
    switch raw {
    case "watching":
      return .watching
    case "detecting":
      return .detecting
    case "idle":
      return .idle
    default:
      return .down
    }
  }
}
