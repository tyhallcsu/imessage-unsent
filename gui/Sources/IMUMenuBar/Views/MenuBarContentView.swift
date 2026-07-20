import AppKit
import SwiftUI
import IMUMenuBarCore

struct MenuBarContentView: View {
  @ObservedObject var model: MenuBarModel
  // Direct scene routing: the imu:// URL round-trip goes through Launch
  // Services, which is a silent no-op in unbundled dev builds and can route
  // to the WRONG copy when two installs share the bundle id. The URL scheme
  // stays for external events (notification clicks, terminal).
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack {
      Label(model.status.menuTitle, systemImage: statusImage)

      // Silent-failure guard: recovery being broken must be visible on the
      // primary surface, not buried in Settings (FDA loss is the #1 field
      // failure after a daemon rebuild changes its code identity).
      if model.status == .down {
        Button {
          openWindow(id: "doctor")
        } label: {
          Label("Daemon not running — run Health Check", systemImage: "exclamationmark.triangle.fill")
        }
      } else if model.fullDiskAccessDenied {
        Button {
          openWindow(id: "settings")
        } label: {
          Label("Full Disk Access needed — recovery is paused", systemImage: "lock.trianglebadge.exclamationmark")
        }
      }

      Divider()

      if model.recentRecoveries.isEmpty {
        Text("No recent recoveries")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.recentRecoveries.prefix(5)) { recovery in
          Button {
            openWindow(id: "history")
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
          .contextMenu {
            Button("Reveal in Finder") {
              NSWorkspace.shared.open(recovery.archiveURL)
            }
          }
        }
      }

      Divider()

      Button("Open History") {
        openWindow(id: "history")
      }
      Button("Health Check…") {
        openWindow(id: "doctor")
      }
      Button("Open Settings") {
        openWindow(id: "settings")
      }
      .keyboardShortcut(",", modifiers: .command)

      Divider()

      Button("About iMessage Unsent…") {
        openWindow(id: "about")
      }
      Button("Quit") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q", modifiers: .command)
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
}
