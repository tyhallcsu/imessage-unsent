import AppKit
import Combine
import IMUMenuBarCore
import SwiftUI
import UserNotifications

@main
struct IMUMenuBarApp: App {
  @NSApplicationDelegateAdaptor(IMUAppDelegate.self) private var appDelegate
  @StateObject private var model = MenuBarModel()
  @StateObject private var settingsModel = SettingsModel()
  @StateObject private var permissionModel = NotificationPermissionModel()
  @StateObject private var restartModel = DaemonRestartModel(
    restarter: DefaultDaemonRestarter(
      pinger: DaemonControlClient(),
      statusFetcher: { DaemonControlClient().status() }
    )
  )
  @Environment(\.openWindow) private var openWindow

  /// GUI-side recovery watcher (issue #94). Polls the archives directory and
  /// posts notifications for new `recovered=true` archives. Held by the
  /// AppDelegate so its lifetime equals the app.
  private static let archivesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("archives", isDirectory: true)

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(model: model)
        .onAppear {
          model.start()
          appDelegate.startRecoveryWatcher(
            archivesDir: Self.archivesDir,
            isEnabled: { [weak settingsModel] in settingsModel?.draft.notifications.show ?? true }
          )
        }
        .onReceive(URLRouter.shared.publisher) { route in
          handle(route: route)
        }
    } label: {
      StatusIconView(status: model.status)
    }
    .menuBarExtraStyle(.menu)

    Window("Recovered Messages", id: "history") {
      HistoryWindow(model: model)
    }
    .handlesExternalEvents(matching: ["history"])

    Window("imessage-unsent Settings", id: "settings") {
      SettingsWindow(
        model: model,
        settingsModel: settingsModel,
        permissionModel: permissionModel,
        restartModel: restartModel
      )
    }
    .handlesExternalEvents(matching: ["settings"])

    Window("imessage-unsent Doctor", id: "doctor") {
      DoctorWindow()
    }
    .handlesExternalEvents(matching: ["doctor"])

    Window("About imessage-unsent", id: "about") {
      AboutWindow()
    }
    .windowResizability(.contentSize)
    .handlesExternalEvents(matching: ["about"])
  }

  private func handle(route: IMURoute) {
    switch route {
    case .history:
      openWindow(id: "history")
    case .settings:
      openWindow(id: "settings")
    case .doctor:
      openWindow(id: "doctor")
    case .about:
      openWindow(id: "about")
    case let .archive(folderURL):
      NSWorkspace.shared.open(folderURL)
    case .unknown:
      break
    }
  }
}

final class IMUAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var recoveryWatcher: RecoveryWatcher?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }

  func startRecoveryWatcher(archivesDir: URL, isEnabled: @escaping () -> Bool) {
    guard recoveryWatcher == nil else { return }
    let watcher = RecoveryWatcher(
      archivesDir: archivesDir,
      isEnabled: isEnabled,
      notifier: defaultRecoveryNotifier
    )
    watcher.start()
    recoveryWatcher = watcher
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      URLRouter.shared.publish(routeIMUURL(url))
    }
  }

  /// Show banners while the app is foregrounded; clicking routes to history.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    URLRouter.shared.publish(.history)
    completionHandler()
  }
}

final class URLRouter {
  static let shared = URLRouter()

  let publisher = PassthroughSubject<IMURoute, Never>()

  private init() {}

  func publish(_ route: IMURoute) {
    publisher.send(route)
  }
}
