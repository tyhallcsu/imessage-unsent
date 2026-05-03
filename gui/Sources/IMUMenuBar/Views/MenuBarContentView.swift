import AppKit
import SwiftUI
import IMUMenuBarCore

struct MenuBarContentView: View {
  @ObservedObject var model: MenuBarModel

  var body: some View {
    VStack {
      Label(model.status.menuTitle, systemImage: statusImage)

      Divider()

      if model.recentRecoveries.isEmpty {
        Text("No recent recoveries")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.recentRecoveries.prefix(5)) { recovery in
          Button {
            NSWorkspace.shared.open(recovery.archiveURL)
          } label: {
            VStack(alignment: .leading) {
              Text(recovery.title)
                .lineLimit(1)
              Text(recovery.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }

      Divider()

      Button("Open History") {
        openAppURL("imu://history")
      }
      Button("Health Check…") {
        openAppURL("imu://doctor")
      }
      Button("Open Settings") {
        openAppURL("imu://settings")
      }
      Button("Quit") {
        NSApp.terminate(nil)
      }
    }
  }

  private var statusImage: String {
    switch model.status {
    case .idle:
      return "circle"
    case .watching:
      return "checkmark.circle"
    case .detecting:
      return "arrow.triangle.2.circlepath.circle"
    case .down:
      return "xmark.octagon"
    }
  }

  private func openAppURL(_ string: String) {
    if let url = URL(string: string) {
      NSWorkspace.shared.open(url)
    }
  }
}
