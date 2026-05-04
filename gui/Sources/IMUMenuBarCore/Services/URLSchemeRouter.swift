import Foundation

public enum IMURoute: Equatable {
  case history
  /// Open History scrolled to (and detail-sheeting) the archive with the
  /// given id (`<TIMESTAMP>Z-<rowid>` directory name). Used by notification
  /// click-throughs and any future "share a recovery" flow.
  case historyEntry(String)
  case settings
  case doctor
  case about
  case archive(URL)
  case unknown
}

public func routeIMUURL(_ url: URL) -> IMURoute {
  guard url.scheme == "imu" else {
    return .unknown
  }
  switch url.host {
  case "history":
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.isEmpty {
      return .history
    }
    // Path component is the archive directory name. Validate against the
    // canonical pattern so a malformed deep-link doesn't drive a UI lookup
    // for arbitrary input.
    let nsPath = path as NSString
    let isWellFormed = archiveIdPattern.firstMatch(
      in: path,
      range: NSRange(location: 0, length: nsPath.length)
    ) != nil
    return isWellFormed ? .historyEntry(path) : .history
  case "settings":
    return .settings
  case "doctor":
    return .doctor
  case "about":
    return .about
  case "archive":
    let path = url.path
    guard !path.isEmpty else {
      return .unknown
    }
    return .archive(URL(fileURLWithPath: path, isDirectory: true))
  default:
    return .unknown
  }
}

// swiftlint:disable:next force_try
private let archiveIdPattern: NSRegularExpression =
  try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{6}Z-\\d+$")

