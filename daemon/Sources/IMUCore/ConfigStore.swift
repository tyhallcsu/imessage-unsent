import Foundation

public struct DaemonConfig: Equatable {
  public var logLevel: String
  public var dataDir: String

  public init(
    logLevel: String = "info",
    dataDir: String = "~/Library/Application Support/imessage-unsent"
  ) {
    self.logLevel = logLevel
    self.dataDir = dataDir
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

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let uncommented = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
      let line = uncommented.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else {
        continue
      }

      let parts = line.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else {
        continue
      }

      switch parts[0] {
      case "log_level":
        config.logLevel = parseString(parts[1])
      case "data_dir":
        config.dataDir = parseString(parts[1])
      default:
        continue
      }
    }

    return config
  }

  private static func parseString(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
      return String(trimmed.dropFirst().dropLast())
    }
    return trimmed
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
