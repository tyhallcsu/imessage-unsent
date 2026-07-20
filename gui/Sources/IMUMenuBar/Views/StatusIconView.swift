import SwiftUI
import IMUMenuBarCore

struct StatusIconView: View {
  let status: DaemonStatus
  var needsAttention: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "message.badge.waveform")
      // Attention uses a distinct SHAPE, not just a color change, so the
      // state reads under monochrome menu bars and for color-blind users.
      if needsAttention {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 8))
          .foregroundStyle(.orange)
      } else {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilitySummary)
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

  private var accessibilitySummary: String {
    needsAttention
      ? "iMessage Unsent: \(status.menuTitle), needs attention"
      : "iMessage Unsent: \(status.menuTitle)"
  }
}
