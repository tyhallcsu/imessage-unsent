import AppKit
import Combine
import IMUMenuBarCore
import SwiftUI
import UserNotifications

@main
struct IMUMenuBarApp: App {
  @NSApplicationDelegateAdaptor(IMUAppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(model: appDelegate.model)
        .onAppear {
          // Re-entry guard only. Bootstrap happens in
          // applicationDidFinishLaunching — with .menu style this content is
          // evaluated lazily on some macOS builds, so nothing vital may run
          // before the user first clicks the icon (#149 / G-3).
          appDelegate.bootstrapIfNeeded()
        }
        .onReceive(URLRouter.shared.publisher) { route in
          handle(route: route)
        }
    } label: {
      StatusIconView(status: appDelegate.model.status, needsAttention: appDelegate.model.needsAttention)
    }
    .menuBarExtraStyle(.menu)

    Window("Recovered Messages", id: "history") {
      HistoryWindow(model: appDelegate.model, pendingDeepLink: appDelegate.pendingDeepLink)
    }
    .handlesExternalEvents(matching: ["history"])

    Window("imessage-unsent Settings", id: "settings") {
      SettingsWindow(
        model: appDelegate.model,
        settingsModel: appDelegate.settingsModel,
        permissionModel: appDelegate.permissionModel,
        restartModel: appDelegate.restartModel
      )
    }
    .handlesExternalEvents(matching: ["settings"])

    Window("imessage-unsent Doctor", id: "doctor") {
      DoctorWindow()
    }
    .handlesExternalEvents(matching: ["doctor"])

    Window("About iMessage Unsent", id: "about") {
      AboutWindow()
    }
    .windowResizability(.contentSize)
    .handlesExternalEvents(matching: ["about"])
  }

  private func handle(route: IMURoute) {
    switch route {
    case .history:
      openWindow(id: "history")
    case let .historyEntry(archiveId):
      appDelegate.pendingDeepLink.archiveId = archiveId
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

/// Owns the app-lifetime services and models. Ownership lives HERE (not in
/// `@StateObject`s bootstrapped from the menu content's `.onAppear`) because
/// `applicationDidFinishLaunching` is the only hook guaranteed to run at
/// launch — `.menu`-style MenuBarExtra content can be evaluated lazily, which
/// previously left status polling and the RecoveryWatcher (the entire
/// notification feature, #94) dead until the user first opened the menu.
@MainActor
final class IMUAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate,
  ObservableObject {
  let model = MenuBarModel()
  let settingsModel = SettingsModel()
  let permissionModel = NotificationPermissionModel()
  let pendingDeepLink = PendingDeepLink()
  let restartModel = DaemonRestartModel(
    restarter: DefaultDaemonRestarter(
      pinger: DaemonControlClient(),
      statusFetcher: { DaemonControlClient().status() }
    )
  )

  private var recoveryWatcher: RecoveryWatcher?
  private var didBootstrap = false
  private var cancellables: Set<AnyCancellable> = []

  /// GUI-side recovery watcher (issue #94). Polls the archives directory and
  /// posts notifications for new `recovered=true` archives.
  private static let archivesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("archives", isDirectory: true)

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    bootstrapIfNeeded()
  }

  func bootstrapIfNeeded() {
    guard !didBootstrap else { return }
    didBootstrap = true
    // The MenuBarExtra LABEL reads model state through this delegate, and
    // the adaptor observes the delegate — model changes must republish here
    // or the status icon freezes at its launch state.
    model.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    model.start()
    let watcher = RecoveryWatcher(
      archivesDir: Self.archivesDir,
      // Saved config, not the draft: unsaved Settings edits must not change
      // live behavior (the pane promises Save-then-apply).
      isEnabled: { [weak settingsModel] in
        settingsModel?.savedConfig.notifications.show ?? true
      },
      previewChars: { [weak settingsModel] in
        settingsModel?.savedConfig.notifications.previewChars ?? 80
      },
      notifier: defaultRecoveryNotifier
    )
    watcher.start()
    recoveryWatcher = watcher
  }

  nonisolated func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      URLRouter.shared.publish(routeIMUURL(url))
    }
  }

  /// Show banners while the app is foregrounded; clicking routes to history.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // RecoveryWatcher stores the archive id under "archive_id" in userInfo.
    // Route to the specific entry's detail when present so notification taps
    // land users on the recovery they got the banner about; fall back to the
    // history list when the id is missing (e.g. older notifications, or the
    // bundled "N messages recovered" coalesced banner).
    let userInfo = response.notification.request.content.userInfo
    if let archiveId = userInfo["archive_id"] as? String, !archiveId.isEmpty {
      URLRouter.shared.publish(.historyEntry(archiveId))
    } else {
      URLRouter.shared.publish(.history)
    }
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
