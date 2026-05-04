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
  /// True between calling `enable()` and the resulting `refresh()` returning,
  /// so the UI can show "Requesting…" and prevent double-clicks.
  @Published public private(set) var isRequesting: Bool = false
  /// Becomes true when `enable()` finishes but `status` did not transition out
  /// of `.notDetermined` — macOS suppresses the prompt after a previous deny
  /// or for sandbox/code-identity reasons. UI flips to "Open System Settings".
  @Published public private(set) var promptSuppressed: Bool = false
  /// Set briefly after `sendTestNotification()` to confirm the click registered.
  @Published public private(set) var lastTestResult: TestResult?

  public enum TestResult: Equatable {
    case sent
    case failed(String)
  }

  private let probe: NotificationPermissionProbing

  public init(probe: NotificationPermissionProbing = DefaultNotificationProbe()) {
    self.probe = probe
  }

  public func refresh() async {
    status = await probe.authorizationStatus()
  }

  public func enable() async {
    isRequesting = true
    promptSuppressed = false
    _ = await probe.requestAuthorization(options: [.alert, .sound])
    await refresh()
    isRequesting = false
    // If the request finished but status is still .notDetermined, macOS
    // declined to prompt the user — the row should pivot to "Open System
    // Settings" instead of dangling at the dead-end "Enable" button.
    promptSuppressed = (status == .notDetermined)
  }

  /// Posts a benign test notification so the user can confirm end-to-end
  /// delivery (banner, sound, click into the app). Only meaningful once
  /// `status` is `.authorized` or `.provisional`; otherwise records a clear
  /// failure reason for the UI.
  public func sendTestNotification() {
    guard status == .authorized || status == .provisional else {
      lastTestResult = .failed("Notifications not authorized — click \"Open System Settings\" first.")
      return
    }
    guard Bundle.main.bundleIdentifier != nil else {
      lastTestResult = .failed("Test notifications require running as a bundled app.")
      return
    }
    let content = UNMutableNotificationContent()
    content.title = "imessage-unsent test"
    content.body = "Notifications are working. You'll see a banner here when a new message is recovered."
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "imu-test-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { [weak self] error in
      Task { @MainActor in
        if let error {
          self?.lastTestResult = .failed("Add request failed: \(error.localizedDescription)")
        } else {
          self?.lastTestResult = .sent
        }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        self?.lastTestResult = nil
      }
    }
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
