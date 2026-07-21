import Foundation

public protocol ConfigFileStoring {
  var configURL: URL { get }
  func load() -> SettingsConfig
  func save(_ config: SettingsConfig) throws
}

/// Reads and writes `~/.config/imessage-unsent/config.toml` using the same TOML
/// shape the daemon's `ConfigStore` understands. Comments and unknown keys are
/// dropped on save (the GUI controls the canonical shape — users who want
/// custom comments can edit the file by hand and accept that the next Save
/// rewrites it).
public final class ConfigFileStore: ConfigFileStoring {
  public let configURL: URL
  private let fileManager: FileManager

  public init(configURL: URL = defaultGUIConfigURL(), fileManager: FileManager = .default) {
    self.configURL = configURL
    self.fileManager = fileManager
  }

  public func load() -> SettingsConfig {
    guard fileManager.fileExists(atPath: configURL.path),
          let text = try? String(contentsOf: configURL, encoding: .utf8) else {
      return SettingsConfig()
    }
    return Self.parse(text)
  }

  public func save(_ config: SettingsConfig) throws {
    let parent = configURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let text = Self.serialize(config)
    try text.write(to: configURL, atomically: true, encoding: .utf8)
    // The file carries the webhook signing secret in plaintext; owner-only,
    // and re-applied on every save because atomic writes replace the inode.
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
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

  /// Public for tests; mirrors the daemon's `ConfigStore.parse` shape.
  public static func parse(_ text: String) -> SettingsConfig {
    var config = SettingsConfig()
    var section = ""

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let uncommented = stripComment(rawLine)
      let line = uncommented.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }

      if line.hasPrefix("["), line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast())
        continue
      }

      let parts = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else { continue }
      let key = parts[0]
      let value = parts[1]

      switch section {
      case "":
        switch key {
        case "log_level":
          config.logLevel = parseString(value)
        case "data_dir":
          config.dataDir = parseString(value)
        case "archive_retention":
          if let intValue = Int(parseString(value)) {
            config.archiveRetention = intValue
          }
        default:
          continue
        }

      case "notifications":
        switch key {
        case "show":
          if let bool = parseBool(value) { config.notifications.show = bool }
        case "preview_chars":
          if let intValue = Int(parseString(value)) {
            config.notifications.previewChars = max(0, min(200, intValue))
          }
        case "webhook":
          config.notifications.webhook = parseString(value)
        case "webhook_signing_secret":
          config.notifications.webhookSigningSecret = parseString(value)
        default:
          continue
        }

      case "experimental":
        if key == "restore_mode", let bool = parseBool(value) {
          config.experimental.restoreMode = bool
        }

      default:
        continue
      }
    }
    return config
  }

  /// Public for tests; mirrors the daemon's `ConfigStore.serialize` shape.
  public static func serialize(_ config: SettingsConfig) -> String {
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
      case let other?: result.append(other)
      case nil: break
      }
    }
    return result
  }

  private static func parseBool(_ value: String) -> Bool? {
    switch parseString(value).lowercased() {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }

  private static func quote(_ value: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(value.count + 2)
    escaped.append("\"")
    for character in value {
      switch character {
      case "\\": escaped.append("\\\\")
      case "\"": escaped.append("\\\"")
      case "\n": escaped.append("\\n")
      case "\r": escaped.append("\\r")
      case "\t": escaped.append("\\t")
      default: escaped.append(character)
      }
    }
    escaped.append("\"")
    return escaped
  }
}

public func defaultGUIConfigURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("config.toml", isDirectory: false)
}
