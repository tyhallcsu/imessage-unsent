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
  @Published public private(set) var recentRecoveries: [RecoverySummary] = []

  private let pinger: DaemonPinging
  private let historyProvider: RecoveryHistoryProviding
  private var timer: Timer?

  public init(
    pinger: DaemonPinging = DaemonSocketClient(),
    historyProvider: RecoveryHistoryProviding = EmptyRecoveryHistoryProvider()
  ) {
    self.pinger = pinger
    self.historyProvider = historyProvider
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
    status = pinger.ping() ? .watching : .down
    recentRecoveries = Array(historyProvider.recentRecoveries(limit: 5).prefix(5))
  }
}
