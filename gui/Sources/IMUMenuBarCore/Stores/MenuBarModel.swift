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

@MainActor
public final class MenuBarModel: ObservableObject {
  @Published public private(set) var status: DaemonStatus = .idle
  @Published public private(set) var statusInfo: DaemonStatusInfo?
  @Published public private(set) var recentRecoveries: [RecoverySummary] = []

  private let pinger: DaemonPinging
  private let historyProvider: RecoveryHistoryProviding
  private let statusProvider: (() -> DaemonStatusInfo?)?
  private var timer: Timer?

  public init(
    pinger: DaemonPinging,
    historyProvider: RecoveryHistoryProviding = EmptyRecoveryHistoryProvider(),
    statusProvider: (() -> DaemonStatusInfo?)? = nil
  ) {
    self.pinger = pinger
    self.historyProvider = historyProvider
    self.statusProvider = statusProvider
  }

  public convenience init() {
    let client = DaemonControlClient()
    self.init(
      pinger: client,
      historyProvider: DaemonHistoryProvider(client: client),
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
