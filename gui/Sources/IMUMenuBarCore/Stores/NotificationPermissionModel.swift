import Foundation
import SwiftUI
import UserNotifications

/// Tracks the GUI app's macOS notification authorization status and exposes
/// actions to request it or jump to System Settings. The daemon
/// (`imu-watcher`) has its own bundle ID and authorization, which this model
/// does not affect.
@MainActor
public final class NotificationPermissionModel: ObservableObject {
  @Published public private(set) var status: UNAuthorizationStatus = .notDetermined

  private let probe: NotificationPermissionProbing

  public init(probe: NotificationPermissionProbing = DefaultNotificationProbe()) {
    self.probe = probe
  }

  public func refresh() async {
    status = await probe.authorizationStatus()
  }

  public func enable() async {
    _ = await probe.requestAuthorization(options: [.alert, .sound])
    await refresh()
  }

  public var statusText: String {
    switch status {
    case .authorized: return "Authorized"
    case .provisional: return "Provisional"
    case .denied: return "Denied"
    case .notDetermined: return "Not yet requested"
    case .ephemeral: return "Ephemeral"
    @unknown default: return "Unknown"
    }
  }

  public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
}
