import SwiftUI
import IMUMenuBarCore

@main
struct IMUMenuBarApp: App {
  @StateObject private var model = MenuBarModel()

  var body: some Scene {
    MenuBarExtra {
      MenuBarContentView(model: model)
        .onAppear {
          model.start()
        }
    } label: {
      StatusIconView(status: model.status)
    }
    .menuBarExtraStyle(.menu)
  }
}
