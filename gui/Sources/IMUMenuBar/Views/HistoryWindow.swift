import AppKit
import IMUMenuBarCore
import SwiftUI

struct HistoryWindow: View {
  @ObservedObject var model: MenuBarModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 480, minHeight: 360)
    .onAppear {
      model.refresh()
    }
  }

  private var header: some View {
    HStack {
      Text("Recovered Messages")
        .font(.headline)
      Spacer()
      Button {
        model.refresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh from daemon")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  @ViewBuilder
  private var content: some View {
    if model.recentRecoveries.isEmpty {
      emptyState
    } else {
      List(model.recentRecoveries) { recovery in
        VStack(alignment: .leading, spacing: 6) {
          Text(recovery.title)
            .textSelection(.enabled)
            .lineLimit(nil)
          HStack {
            Text(recovery.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Open archive") {
              NSWorkspace.shared.open(recovery.archiveURL)
            }
            .buttonStyle(.link)
          }
        }
        .padding(.vertical, 4)
      }
      .listStyle(.inset)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "tray")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)
      Text(model.status == .down ? "Daemon is not running" : "No recoveries yet")
        .foregroundStyle(.secondary)
      if model.status == .down {
        Text("Start imu-watcher to begin watching chat.db.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
