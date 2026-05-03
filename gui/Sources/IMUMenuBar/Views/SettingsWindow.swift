import AppKit
import IMUMenuBarCore
import SwiftUI

struct SettingsWindow: View {
  @ObservedObject var model: MenuBarModel
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var restartModel: DaemonRestartModel

  var body: some View {
    Form {
      daemonSection
      notificationsSection
      storageSection
      diagnosticsSection
      footerSection
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 540)
    .onAppear {
      model.refresh()
    }
    .toolbar {
      ToolbarItemGroup(placement: .confirmationAction) {
        if settingsModel.isDirty {
          Button("Revert") { settingsModel.revertEdits() }
            .keyboardShortcut(".", modifiers: .command)
        }
        Button("Save") {
          settingsModel.save()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!settingsModel.isDirty)
      }
    }
  }

  // MARK: Sections

  private var daemonSection: some View {
    Section("Daemon") {
      statusRow
      infoRow(label: "Version", value: model.statusInfo?.version ?? "—")
      infoRow(label: "Uptime", value: uptimeText)
      infoRow(label: "Recoveries observed", value: "\(model.statusInfo?.recoveryCount ?? 0)")
      infoRow(label: "Last WAL change", value: model.statusInfo?.lastWalChangeAt ?? "never")
      if let lastError = model.statusInfo?.lastError, !lastError.isEmpty {
        infoRow(label: "Last error", value: lastError)
      }
      restartRow
    }
  }

  @ViewBuilder
  private var restartRow: some View {
    HStack {
      Button {
        Task {
          await restartModel.restart()
          model.refresh()
        }
      } label: {
        if restartModel.isRestarting {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Restarting…")
          }
        } else {
          Text("Restart imu-watcher")
        }
      }
      .disabled(restartModel.isRestarting)
      .help("Sends `launchctl kickstart -k` to the watcher LaunchAgent and waits for it to come back up.")

      Spacer()

      switch restartModel.state {
      case .idle:
        EmptyView()
      case .restarting:
        EmptyView()
      case let .succeeded(message):
        Label(message, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.callout)
          .lineLimit(2)
      case let .failed(reason):
        Label(reason, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.callout)
          .lineLimit(2)
      }
    }
  }

  private var notificationsSection: some View {
    Section("Notifications") {
      Toggle("Show macOS notifications", isOn: $settingsModel.draft.notifications.show)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Preview length")
          Spacer()
          Text("\(settingsModel.draft.notifications.previewChars) chars")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Slider(
          value: Binding(
            get: { Double(settingsModel.draft.notifications.previewChars) },
            set: { settingsModel.draft.notifications.previewChars = Int($0) }
          ),
          in: 0...200,
          step: 10
        )
        .disabled(!settingsModel.draft.notifications.show)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Webhook URL")
          .font(.callout)
        TextField(
          "https://example.com/imu",
          text: $settingsModel.draft.notifications.webhook
        )
        .textFieldStyle(.roundedBorder)
        .disableAutocorrection(true)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Webhook signing secret")
          .font(.callout)
        SecureField(
          "(used to HMAC-sign webhook requests)",
          text: $settingsModel.draft.notifications.webhookSigningSecret
        )
        .textFieldStyle(.roundedBorder)
      }
    }
  }

  private var storageSection: some View {
    Section("Storage") {
      infoRow(label: "Data dir", value: model.statusInfo?.dataDir ?? settingsModel.draft.dataDir)
      Button("Reveal data dir in Finder") {
        revealDataDir()
      }
      .disabled(dataDirURL() == nil)

      Picker("Archive retention", selection: $settingsModel.draft.archiveRetention) {
        ForEach(settingsRetentionChoices, id: \.self) { count in
          Text("Last \(count)").tag(count)
        }
      }
      .help("Older archives beyond this count are pruned automatically by the daemon.")
    }
  }

  private var diagnosticsSection: some View {
    Section("Diagnostics") {
      Button("Reveal config file in Finder") {
        revealConfigFile()
      }
      Button("Reveal archives dir in Finder") {
        revealArchivesDir()
      }
      .disabled(dataDirURL() == nil)
      Button("Copy daemon socket path") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(defaultDaemonSocketURL().path, forType: .string)
      }
    }
  }

  private var footerSection: some View {
    Section {
      if let lastError = settingsModel.lastSaveError {
        Label(lastError, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      } else if let savedAt = settingsModel.didSaveAt {
        Label("Saved at \(savedAtText(savedAt)). Restart imu-watcher to apply changes.", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        Text("Settings are written to \(settingsModel.configURL.path). Restart imu-watcher (\(restartHint)) to apply changes.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if settingsModel.draft.experimental.restoreMode {
        Label("Restore mode is enabled in config — currently has no effect (see issue #16).", systemImage: "exclamationmark.shield")
          .foregroundStyle(.orange)
          .font(.caption)
      }
    }
  }

  // MARK: Status helpers

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
    case .watching: return "checkmark.circle"
    case .detecting: return "arrow.triangle.2.circlepath.circle"
    case .idle: return "circle"
    case .down: return "xmark.octagon"
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
    guard let seconds = model.statusInfo?.uptimeSeconds else { return "—" }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
  }

  private var restartHint: String {
    "launchctl kickstart -k gui/$(id -u)/com.imu.watcher"
  }

  // MARK: Buttons

  private func dataDirURL() -> URL? {
    if let path = model.statusInfo?.dataDir {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return nil
  }

  private func revealDataDir() {
    if let url = dataDirURL() {
      NSWorkspace.shared.open(url)
    }
  }

  private func revealArchivesDir() {
    if let dataDir = dataDirURL() {
      let archives = dataDir.appendingPathComponent("archives", isDirectory: true)
      NSWorkspace.shared.open(archives)
    }
  }

  private func revealConfigFile() {
    let url = settingsModel.configURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
  }

  private func savedAtText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    formatter.dateStyle = .none
    return formatter.string(from: date)
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
