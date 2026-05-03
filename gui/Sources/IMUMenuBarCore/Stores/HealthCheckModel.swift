import Foundation

/// Drives the App Doctor window. Wraps a `HealthChecking` so the same model
/// works against the live daemon or any test stub.
@MainActor
public final class HealthCheckModel: ObservableObject {
  @Published public private(set) var checks: [HealthCheck] = []
  @Published public private(set) var isLoading = false
  @Published public private(set) var lastRunAt: Date?

  public let appVersion: String

  private let checker: HealthChecking
  private let now: () -> Date

  public init(
    checker: HealthChecking,
    appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
    now: @escaping () -> Date = Date.init
  ) {
    self.checker = checker
    self.appVersion = appVersion
    self.now = now
  }

  /// Re-runs all checks. Re-entrant: if a run is already in flight, the second
  /// call is a no-op so a double-click cannot double-execute the probes.
  public func reload() async {
    if isLoading { return }
    isLoading = true
    let result = await checker.runAll().sortedForDisplay()
    checks = result
    lastRunAt = now()
    isLoading = false
  }

  /// Plain-text report ready to drop on the pasteboard. Picks the daemon
  /// version out of the last run's `daemon.status` row when available.
  public func diagnosticsText() -> String {
    let daemonReachable: Bool = {
      guard let row = checks.first(where: { $0.id == "daemon.running" }) else { return false }
      return row.severity == .pass
    }()
    let daemonVersion: String? = {
      guard let row = checks.first(where: { $0.id == "daemon.status" }),
            row.severity == .pass || row.severity == .warn,
            let detail = row.detail else { return nil }
      for line in detail.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("version:") {
          return trimmed
            .split(separator: ":", maxSplits: 1)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        }
      }
      return nil
    }()
    return Diagnostics.report(
      checks: checks,
      appVersion: appVersion,
      daemonVersion: daemonVersion,
      daemonReachable: daemonReachable,
      now: now()
    )
  }
}
