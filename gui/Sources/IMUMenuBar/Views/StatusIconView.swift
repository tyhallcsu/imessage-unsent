import SwiftUI
import IMUMenuBarCore

struct StatusIconView: View {
  let status: DaemonStatus

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "message.badge.waveform")
      Circle()
        .fill(statusColor)
        .frame(width: 7, height: 7)
        .accessibilityLabel(status.menuTitle)
    }
  }

  private var statusColor: Color {
    switch status {
    case .idle:
      return .gray
    case .watching:
      return .green
    case .detecting:
      return .blue
    case .down:
      return .red
    }
  }
}
