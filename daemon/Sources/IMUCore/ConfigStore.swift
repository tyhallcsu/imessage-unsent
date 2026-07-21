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

  /// Atomically serializes `config` to TOML and writes it to `url`. Creates
  /// parent directories with `0o700` if missing. Always reflects the full
  /// config — comments in any pre-existing file are NOT preserved (this is
  /// the same behavior as TOMLKit and tomli_w; users who want comments can
  /// use the GUI which never round-trips them away unintentionally because
  /// the field set is fixed).
  public func save(_ config: DaemonConfig) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let text = Self.serialize(config)
    try text.write(to: url, atomically: true, encoding: .utf8)
    // Carries webhook_signing_secret in plaintext; owner-only, re-applied on
    // every save because atomic writes replace the inode (#144).
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// Returns the canonical TOML representation of `config`. The output round-
  /// trips through `parse` to an `Equatable` value (`parse(serialize(c)) == c`).
  public static func serialize(_ config: DaemonConfig) -> String {
    var lines: [String] = []
    lines.append("# imessage-unsent daemon config")
    lines.append("# Managed by the menu bar Settings pane; safe to edit by hand.")
    lines.append("")
    lines.append("log_level = \(quote(config.logLevel))")
    lines.append("data_dir = \(quote(config.dataDir))")
    lines.append("archive_retention = \(config.archiveRetention)")
    lines.append("")
    lines.append("[notifications]")
    lines.append("show = \(config.notifications.show)")
    lines.append("preview_chars = \(config.notifications.previewChars)")
    lines.append("webhook = \(quote(config.notifications.webhook))")
    lines.append("webhook_signing_secret = \(quote(config.notifications.webhookSigningSecret))")
    lines.append("")
    lines.append("[experimental]")
    lines.append("restore_mode = \(config.experimental.restoreMode)")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func quote(_ value: String) -> String {
    // TOML basic-string escapes: backslash, quote, control chars. The config
    // values we care about are user paths, URLs, and short secrets — none of
    // which legitimately contain control chars or newlines, so we keep this
    // minimal and reject anything with embedded newlines by collapsing them.
    var escaped = ""
    escaped.reserveCapacity(value.count + 2)
    escaped.append("\"")
    for character in value {
      switch character {
      case "\\":
        escaped.append("\\\\")
      case "\"":
        escaped.append("\\\"")
      case "\n":
        escaped.append("\\n")
      case "\r":
        escaped.append("\\r")
      case "\t":
        escaped.append("\\t")
      default:
        escaped.append(character)
      }
    }
    escaped.append("\"")
    return escaped
  }


  /// Strips a trailing comment — only a `#` OUTSIDE a quoted string starts a
  /// comment. Splitting on the first raw `#` truncated quoted values
  /// ("abc#def" parsed back as `"abc`), corrupting saved signing secrets and
  /// URLs and breaking the parse(serialize(c)) == c contract (#144).
  private static func stripComment(_ line: Substring) -> String {
    var inQuotes = false
    var escaped = false
    for (index, character) in zip(line.indices, line) {
      if escaped {
        escaped = false
        continue
      }
      switch character {
      case "\\" where inQuotes:
        escaped = true
      case "\"":
        inQuotes.toggle()
      case "#" where !inQuotes:
        return String(line[..<index])
      default:
        break
      }
    }
    return String(line)
  }

  public static func parse(_ text: String) -> DaemonConfig {
    var config = DaemonConfig()
    var section = ""

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let uncommented = stripComment(rawLine)
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
    guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
      return trimmed
    }
    let inner = trimmed.dropFirst().dropLast()
    var result = ""
    result.reserveCapacity(inner.count)
    var iterator = inner.makeIterator()
    while let character = iterator.next() {
      guard character == "\\" else {
        result.append(character)
        continue
      }
      switch iterator.next() {
      case "\\": result.append("\\")
      case "\"": result.append("\"")
      case "n": result.append("\n")
      case "r": result.append("\r")
      case "t": result.append("\t")
      case let other?: result.append(other) // unknown escape: keep the next char verbatim
      case nil: break
      }
    }
    return result
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

public func expandTilde(_ path: String, home: URL = imuUserHomeDirectory()) -> URL {
  if path == "~" {
    return home
  }
  if path.hasPrefix("~/") {
    return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: false)
  }
  return URL(fileURLWithPath: path)
}

public func defaultConfigURL(home: URL = imuUserHomeDirectory()) -> URL {
  home
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("config.toml", isDirectory: false)
}
