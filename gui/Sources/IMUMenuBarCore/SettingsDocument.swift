import Foundation

public struct AppSettings: Equatable {
  public var notificationsEnabled: Bool = true
  public var previewChars: Int = 80
  public var webhookURL: String = ""
  public var webhookSecret: String = ""
  public var retentionLimit: Int = 100
  public var allowList: [String] = []
  public var denyList: [String] = []

  public init() {}
}

public struct SettingsDocument {
  public var rawText: String

  public init(rawText: String = "") {
    self.rawText = rawText
  }

  public func parse() -> AppSettings {
    var settings = AppSettings()
    var section = ""
    for raw in rawText.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        section = String(trimmed.dropFirst().dropLast())
        continue
      }
      let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else { continue }
      let key = section.isEmpty ? parts[0] : "\(section).\(parts[0])"
      switch key {
      case "notifications.show": settings.notificationsEnabled = parts[1] == "true"
      case "notifications.preview_chars": settings.previewChars = Int(parts[1]) ?? settings.previewChars
      case "notifications.webhook": settings.webhookURL = unquote(parts[1])
      case "notifications.webhook_signing_secret": settings.webhookSecret = unquote(parts[1])
      case "retention.keep_last": settings.retentionLimit = Int(parts[1]) ?? settings.retentionLimit
      case "filters.allow": settings.allowList = parseArray(parts[1])
      case "filters.deny": settings.denyList = parseArray(parts[1])
      default: continue
      }
    }
    return settings
  }

  public func updating(_ settings: AppSettings) -> String {
    var text = rawText
    text = replaceOrAppend(key: "show", section: "notifications", value: "\(settings.notificationsEnabled)", in: text)
    text = replaceOrAppend(key: "preview_chars", section: "notifications", value: "\(settings.previewChars)", in: text)
    text = replaceOrAppend(key: "webhook", section: "notifications", value: quote(settings.webhookURL), in: text)
    text = replaceOrAppend(key: "webhook_signing_secret", section: "notifications", value: quote(settings.webhookSecret), in: text)
    text = replaceOrAppend(key: "keep_last", section: "retention", value: "\(settings.retentionLimit)", in: text)
    text = replaceOrAppend(key: "allow", section: "filters", value: renderArray(settings.allowList), in: text)
    text = replaceOrAppend(key: "deny", section: "filters", value: renderArray(settings.denyList), in: text)
    text = replaceOrAppend(key: "restore_mode", section: "experimental", value: "false", in: text)
    return text
  }
}

private func replaceOrAppend(key: String, section: String, value: String, in text: String) -> String {
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  var current = ""
  var sectionIndex: Int?
  for index in lines.indices {
    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
      current = String(trimmed.dropFirst().dropLast())
      if current == section { sectionIndex = index }
      continue
    }
    if current == section,
       trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key {
      lines[index] = "\(key) = \(value)"
      return lines.joined(separator: "\n")
    }
  }
  if let sectionIndex {
    lines.insert("\(key) = \(value)", at: min(sectionIndex + 1, lines.count))
  } else {
    if !lines.isEmpty, lines.last != "" { lines.append("") }
    lines.append("[\(section)]")
    lines.append("\(key) = \(value)")
  }
  return lines.joined(separator: "\n")
}

private func unquote(_ value: String) -> String {
  value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

private func quote(_ value: String) -> String {
  "\"\(value)\""
}

private func parseArray(_ value: String) -> [String] {
  let trimmed = value.trimmingCharacters(in: .whitespaces)
  guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
  let body = trimmed.dropFirst().dropLast()
  if body.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
  return body.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
}

private func renderArray(_ values: [String]) -> String {
  "[" + values.map(quote).joined(separator: ", ") + "]"
}
