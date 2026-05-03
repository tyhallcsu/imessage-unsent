import Foundation

public enum IMURoute: Equatable {
  case history
  case settings
  case doctor
  case archive(URL)
  case unknown
}

public func routeIMUURL(_ url: URL) -> IMURoute {
  guard url.scheme == "imu" else {
    return .unknown
  }
  switch url.host {
  case "history":
    return .history
  case "settings":
    return .settings
  case "doctor":
    return .doctor
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
