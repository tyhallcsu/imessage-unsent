import Foundation
import SwiftUI

/// Drives the "Restart imu-watcher" button in the Settings pane. Owns the
/// in-flight state plus the last-attempt outcome so the view can render a
/// status line below the button.
@MainActor
public final class DaemonRestartModel: ObservableObject {
  public enum State: Equatable {
    case idle
    case restarting
    case succeeded(message: String)
    case failed(reason: String)
  }

  @Published public private(set) var state: State = .idle

  private let restarter: DaemonRestarting

  public init(restarter: DaemonRestarting) {
    self.restarter = restarter
  }

  public var isRestarting: Bool {
    if case .restarting = state { return true }
    return false
  }

  public func restart() async {
    state = .restarting
    let outcome = await restarter.restart()
    switch outcome {
    case let .succeeded(startedAt):
      state = .succeeded(message: "Restarted (started at \(startedAt))")
    case let .launchctlFailed(stderr, exitCode):
      let detail = stderr.isEmpty ? "launchctl exit \(exitCode)" : stderr
      state = .failed(reason: detail)
    case let .timedOut(seconds):
      state = .failed(reason: "Daemon did not respond within \(seconds)s")
    }
  }
}
