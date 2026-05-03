import Foundation

/// Formats a `[HealthCheck]` array into a UTF-8 plain-text report safe to paste
/// into a GitHub issue or chat. Paths are kept as-is — this is a personal
/// debugging tool and the user is reading their own machine's state.
public enum Diagnostics {
  public static func report(
    checks: [HealthCheck],
    appVersion: String,
    daemonVersion: String?,
    daemonReachable: Bool,
    now: Date = Date()
  ) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    var lines: [String] = []
    lines.append("imessage-unsent diagnostics — \(formatter.string(from: now))")
    lines.append("GUI version: \(appVersion)")
    if let daemonVersion {
      lines.append("Daemon version: \(daemonVersion) (\(daemonReachable ? "running" : "not reachable"))")
    } else {
      lines.append("Daemon version: \(daemonReachable ? "running, version unavailable" : "not reachable")")
    }
    lines.append("")

    for check in checks.sortedForDisplay() {
      lines.append("[\(check.severity.rawValue.uppercased())] \(check.id) — \(check.title)")
      lines.append("       \(check.summary)")
      if let detail = check.detail, !detail.isEmpty {
        for detailLine in detail.split(separator: "\n", omittingEmptySubsequences: false) {
          lines.append("       \(detailLine)")
        }
      }
      if let remediation = check.remediation, !remediation.isEmpty {
        lines.append("       Remediation: \(remediation)")
      }
      lines.append("")
    }
    while lines.last == "" {
      lines.removeLast()
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
