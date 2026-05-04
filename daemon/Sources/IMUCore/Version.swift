import Foundation

public let imuDaemonVersion = "0.3.0"

/// Returns the user's home directory honoring the `HOME` environment variable
/// when present. `FileManager.default.homeDirectoryForCurrentUser` reads from
/// `getpwuid(3)` and ignores `$HOME`, which makes the daemon impossible to
/// integration-test under a fake `$HOME`. This helper is the single source of
/// truth for the home directory across all `default*URL` helpers.
public func imuUserHomeDirectory() -> URL {
  if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
    return URL(fileURLWithPath: envHome, isDirectory: true)
  }
  return FileManager.default.homeDirectoryForCurrentUser
}
