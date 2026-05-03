import AppKit
import IMUMenuBarCore
import SwiftUI

struct SettingsWindow: View {
  @ObservedObject var model: MenuBarModel

  var body: some View {
    Form {
      Section("Daemon") {
        statusRow
        infoRow(label: "Version", value: model.statusInfo?.version ?? "—")
        infoRow(label: "Uptime", value: uptimeText)
        infoRow(label: "Recoveries observed", value: "\(model.statusInfo?.recoveryCount ?? 0)")
        infoRow(label: "Last WAL change", value: model.statusInfo?.lastWalChangeAt ?? "never")
        if let lastError = model.statusInfo?.lastError, !lastError.isEmpty {
          infoRow(label: "Last error", value: lastError)
        }
      }

      Section("Notifications") {
        Toggle(
          "Show macOS notifications",
          isOn: .constant(model.statusInfo?.notificationsShow ?? false)
        )
        .disabled(true)
      }

      Section("Storage") {
        infoRow(label: "Data dir", value: model.statusInfo?.dataDir ?? "—")
        if let dataDir = model.statusInfo?.dataDir {
          Button("Reveal in Finder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: dataDir, isDirectory: true))
          }
        }
      }

      Section {
        Text("Edit ~/.config/imessage-unsent/config.toml and restart the daemon to change settings.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 480, minHeight: 420)
    .onAppear {
      model.refresh()
    }
  }

  private var statusRow: some View {
    HStack {
      Text("Status")
      Spacer()
      Label(model.status.menuTitle, systemImage: statusSymbol)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(statusColor)
    }
  }

  private var statusSymbol: String {
    switch model.status {
    case .watching:
      return "checkmark.circle"
    case .detecting:
      return "arrow.triangle.2.circlepath.circle"
    case .idle:
      return "circle"
    case .down:
      return "xmark.octagon"
    }
  }

  private var statusColor: Color {
    switch model.status {
    case .watching: return .green
    case .detecting: return .blue
    case .idle: return .secondary
    case .down: return .red
    }
  }

  private var uptimeText: String {
    guard let seconds = model.statusInfo?.uptimeSeconds else {
      return "—"
    }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
  }

  private func infoRow(label: String, value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(2)
        .multilineTextAlignment(.trailing)
    }
  }
}
