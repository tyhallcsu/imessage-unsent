import Foundation

public enum DaemonRestartOutcome: Equatable {
  /// launchctl kickstart succeeded and the daemon came back up with a fresh
  /// `started_at` (i.e. a different process than the one we kicked).
  case succeeded(startedAt: String)
  /// launchctl returned a non-zero exit, with the captured stderr.
  case launchctlFailed(stderr: String, exitCode: Int32)
  /// launchctl returned 0 but the control socket never responded (or kept
  /// returning the old `started_at`) within the timeout.
  case timedOut(seconds: Int)
}

public protocol DaemonRestarting {
  func restart() async -> DaemonRestartOutcome
}

/// Restarts the watcher daemon by shelling out to `launchctl kickstart -k`
/// and polling the control socket until a fresh `started_at` is reported.
/// All side-effecting bits (launchctl invocation, ping, status fetch, sleep,
/// clock) are injectable so tests never spawn a real process or open a real
/// socket.
public final class DefaultDaemonRestarter: DaemonRestarting {
  public typealias LaunchctlRun = (_ executable: String, _ arguments: [String]) -> LaunchctlRunResult

  public struct LaunchctlRunResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
      self.exitCode = exitCode
      self.stdout = stdout
      self.stderr = stderr
    }
  }

  private let serviceTarget: String
  private let pinger: DaemonPinging
  private let statusFetcher: () -> DaemonStatusInfo?
  private let run: LaunchctlRun
  private let pollInterval: TimeInterval
  private let pollTimeout: TimeInterval
  private let now: () -> Date
  private let sleep: (TimeInterval) async -> Void

  public init(
    serviceTarget: String = DefaultDaemonRestarter.defaultServiceTarget(),
    pinger: DaemonPinging,
    statusFetcher: @escaping () -> DaemonStatusInfo?,
    run: @escaping LaunchctlRun = DefaultDaemonRestarter.realRun,
    pollIntervalSeconds: TimeInterval = 0.25,
    pollTimeoutSeconds: TimeInterval = 8.0,
    now: @escaping () -> Date = Date.init,
    sleep: @escaping (TimeInterval) async -> Void = DefaultDaemonRestarter.realSleep
  ) {
    self.serviceTarget = serviceTarget
    self.pinger = pinger
    self.statusFetcher = statusFetcher
    self.run = run
    self.pollInterval = pollIntervalSeconds
    self.pollTimeout = pollTimeoutSeconds
    self.now = now
    self.sleep = sleep
  }

  public static func defaultServiceTarget(uid: uid_t = getuid()) -> String {
    "gui/\(uid)/com.imu.watcher"
  }

  public func restart() async -> DaemonRestartOutcome {
    let priorStartedAt = statusFetcher()?.startedAt
    let result = run("/bin/launchctl", ["kickstart", "-k", serviceTarget])
    guard result.exitCode == 0 else {
      let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      return .launchctlFailed(stderr: trimmed, exitCode: result.exitCode)
    }

    let deadline = now().addingTimeInterval(pollTimeout)
    while now() < deadline {
      await sleep(pollInterval)
      guard pinger.ping() else { continue }
      if let info = statusFetcher() {
        if info.startedAt != priorStartedAt {
          return .succeeded(startedAt: info.startedAt)
        }
      }
    }
    return .timedOut(seconds: Int(pollTimeout))
  }

  public static let realRun: LaunchctlRun = { executable, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
      try process.run()
    } catch {
      return LaunchctlRunResult(
        exitCode: -1,
        stdout: "",
        stderr: "failed to launch \(executable): \(error.localizedDescription)"
      )
    }
    process.waitUntilExit()
    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return LaunchctlRunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }

  public static let realSleep: (TimeInterval) async -> Void = { seconds in
    let nanos = UInt64((seconds * 1_000_000_000).rounded())
    try? await Task.sleep(nanoseconds: nanos)
  }
}
