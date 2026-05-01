import Foundation

public struct DaemonConfig: Codable, Equatable {
  public var logLevel: String = "info"
  public var dataDir: String = "~/Library/Application Support/imessage-unsent"
  public var messagesDir: String = "~/Library/Messages"
  public var retentionLimit: Int = 100
  public var notificationsShow: Bool = true
  public var notificationPreviewChars: Int = 80
  public var webhook: String = ""
  public var webhookSigningSecret: String = ""
  public var filterAllow: [String] = []
  public var filterDeny: [String] = []
  public var restoreMode: Bool = false

  public init() {}
}

public final class ConfigStore {
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

  public func save(_ config: DaemonConfig) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.render(config).write(to: url, atomically: true, encoding: .utf8)
  }

  public static func parse(_ text: String) -> DaemonConfig {
    var config = DaemonConfig()
    var section = ""
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        section = String(trimmed.dropFirst().dropLast())
        continue
      }
      let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else { continue }
      let key = section.isEmpty ? parts[0] : "\(section).\(parts[0])"
      let value = parts[1]
      switch key {
      case "log_level": config.logLevel = parseString(value)
      case "data_dir": config.dataDir = parseString(value)
      case "messages_dir": config.messagesDir = parseString(value)
      case "retention.keep_last": config.retentionLimit = parseInt(value) ?? config.retentionLimit
      case "notifications.show": config.notificationsShow = parseBool(value) ?? config.notificationsShow
      case "notifications.preview_chars": config.notificationPreviewChars = parseInt(value) ?? config.notificationPreviewChars
      case "notifications.webhook": config.webhook = parseString(value)
      case "notifications.webhook_signing_secret": config.webhookSigningSecret = parseString(value)
      case "filters.allow": config.filterAllow = parseStringArray(value)
      case "filters.deny": config.filterDeny = parseStringArray(value)
      case "experimental.restore_mode": config.restoreMode = parseBool(value) ?? false
      default: continue
      }
    }
    return config
  }

  public static func render(_ config: DaemonConfig) -> String {
    """
    log_level = "\(config.logLevel)"
    data_dir = "\(config.dataDir)"
    messages_dir = "\(config.messagesDir)"

    [retention]
    keep_last = \(config.retentionLimit)

    [notifications]
    show = \(config.notificationsShow)
    preview_chars = \(config.notificationPreviewChars)
    webhook = "\(config.webhook)"
    webhook_signing_secret = "\(config.webhookSigningSecret)"

    [filters]
    allow = \(renderArray(config.filterAllow))
    deny = \(renderArray(config.filterDeny))

    [experimental]
    restore_mode = false
    """
  }

  private static func parseString(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  private static func parseBool(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }

  private static func parseInt(_ value: String) -> Int? {
    Int(value)
  }

  private static func parseStringArray(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
    let body = trimmed.dropFirst().dropLast()
    if body.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
    return body.split(separator: ",").map { parseString($0.trimmingCharacters(in: .whitespaces)) }
  }

  private static func renderArray(_ values: [String]) -> String {
    "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
  }
}

public func expandTilde(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  if path == "~" {
    return home
  }
  if path.hasPrefix("~/") {
    return home.appendingPathComponent(String(path.dropFirst(2)))
  }
  return URL(fileURLWithPath: path)
}
