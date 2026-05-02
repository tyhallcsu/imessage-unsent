import Foundation

public struct DaemonConfig: Equatable {
  public var logLevel: String
  public var dataDir: String
  public var archiveRetention: Int
  public var notifications: NotificationConfig
  public var experimental: ExperimentalConfig

  public init(
    logLevel: String = "info",
    dataDir: String = "~/Library/Application Support/imessage-unsent",
    archiveRetention: Int = 100,
    notifications: NotificationConfig = NotificationConfig(),
    experimental: ExperimentalConfig = ExperimentalConfig()
  ) {
    self.logLevel = logLevel
    self.dataDir = dataDir
    self.archiveRetention = archiveRetention
    self.notifications = notifications
    self.experimental = experimental
  }
}

public struct NotificationConfig: Equatable {
  public var show: Bool
  public var previewChars: Int
  public var webhook: String
  public var webhookSigningSecret: String

  public init(
    show: Bool = true,
    previewChars: Int = 80,
    webhook: String = "",
    webhookSigningSecret: String = ""
  ) {
    self.show = show
    self.previewChars = previewChars
    self.webhook = webhook
    self.webhookSigningSecret = webhookSigningSecret
  }
}

/// Toggles for capabilities that are off-by-default and require explicit user
/// consent before any code path that depends on them is allowed to run.
///
/// Today the only flag is ``restoreMode`` — a guard for future write-back
/// behavior tracked in issue #16 (experimental "Restore" mode). The daemon
/// shipped in v0.2 is **Notify-only**: it observes retractions and recovers
/// the original text into the archive, but never modifies live `chat.db`.
/// Codified by issue #17.
public struct ExperimentalConfig: Equatable {
  /// When `true`, future code paths are permitted to write to live `chat.db`.
  /// Must be paired with an explicit user-consent flow (issue #16) before any
  /// such code path is wired up. Default: `false`.
  ///
  /// Today no daemon code writes to `chat.db`; this flag exists to make the
  /// invariant testable (see ``RestoreModeGuard``) and to fail-closed if any
  /// future PR adds a write path without the consent flow in place.
  public var restoreMode: Bool

  public init(restoreMode: Bool = false) {
    self.restoreMode = restoreMode
  }
}

public struct ConfigStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() throws -> DaemonConfig {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return DaemonConfig()
    }

    let text = try String(contentsOf: url, encoding: .utf8)
    return Self.parse(text)
  }

  public static func parse(_ text: String) -> DaemonConfig {
    var config = DaemonConfig()
    var section = ""

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let uncommented = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      let line = uncommented.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else {
        continue
      }

      if line.hasPrefix("["), line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast())
        continue
      }

      let parts = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else {
        continue
      }

      if section == "notifications" {
        applyNotificationValue(key: parts[0], value: parts[1], config: &config)
        continue
      }

      if section == "experimental" {
        applyExperimentalValue(key: parts[0], value: parts[1], config: &config)
        continue
      }

      switch parts[0] {
      case "log_level":
        config.logLevel = parseString(parts[1])
      case "data_dir":
        config.dataDir = parseString(parts[1])
      case "archive_retention":
        if let value = Int(parseString(parts[1])) {
          config.archiveRetention = value
        }
      default:
        continue
      }
    }

    return config
  }

  private static func applyExperimentalValue(key: String, value: String, config: inout DaemonConfig) {
    switch key {
    case "restore_mode":
      if let restoreMode = parseBool(value) {
        config.experimental.restoreMode = restoreMode
      }
    default:
      return
    }
  }

  private static func applyNotificationValue(key: String, value: String, config: inout DaemonConfig) {
    switch key {
    case "show":
      if let show = parseBool(value) {
        config.notifications.show = show
      }
    case "preview_chars":
      if let previewChars = Int(parseString(value)) {
        config.notifications.previewChars = max(0, previewChars)
      }
    case "webhook":
      config.notifications.webhook = parseString(value)
    case "webhook_signing_secret":
      config.notifications.webhookSigningSecret = parseString(value)
    default:
      return
    }
  }

  private static func parseString(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
      return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
  }

  private static func parseBool(_ value: String) -> Bool? {
    switch parseString(value).lowercased() {
    case "true":
      return true
    case "false":
      return false
    default:
      return nil
    }
  }
}

public func expandTilde(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  if path == "~" {
    return home
  }
  if path.hasPrefix("~/") {
    return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: false)
  }
  return URL(fileURLWithPath: path)
}

public func defaultConfigURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("config.toml", isDirectory: false)
}
