import AppKit
import Combine
import IMUMenuBarCore
import SwiftUI

@main
struct IMUMenuBarApp: App {
  @NSApplicationDelegateAdaptor(IMUAppDelegate.self) private var appDelegate
  @StateObject private var model = MenuBarModel()
  @StateObject private var settingsModel = SettingsModel()
  @StateObject private var restartModel = DaemonRestartModel(
    restarter: DefaultDaemonRestarter(
      pinger: DaemonControlClient(),
      statusFetcher: { DaemonControlClient().status() }
    )
  )
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(model: model)
        .onAppear {
          model.start()
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
      SettingsWindow(model: model, settingsModel: settingsModel, restartModel: restartModel)
    }
    .handlesExternalEvents(matching: ["settings"])

    Window("imessage-unsent Doctor", id: "doctor") {
      DoctorWindow()
    }
    .handlesExternalEvents(matching: ["doctor"])
  }

  private func handle(route: IMURoute) {
    switch route {
    case .history:
      openWindow(id: "history")
    case .settings:
      openWindow(id: "settings")
    case .doctor:
      openWindow(id: "doctor")
    case let .archive(folderURL):
      NSWorkspace.shared.open(folderURL)
    case .unknown:
      break
    }
  }
}

final class IMUAppDelegate: NSObject, NSApplicationDelegate {
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      URLRouter.shared.publish(routeIMUURL(url))
    }
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
