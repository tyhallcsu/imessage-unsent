import AppKit
import IMUMenuBarCore
import SwiftUI
import UserNotifications

struct SettingsWindow: View {
  @ObservedObject var model: MenuBarModel
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var permissionModel: NotificationPermissionModel
  @ObservedObject var restartModel: DaemonRestartModel
  @StateObject private var contactsModel = ContactsPermissionModel()

  var body: some View {
    Form {
      daemonSection
      notificationsSection
      contactsSection
      storageSection
      diagnosticsSection
      footerSection
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 540)
    .onAppear {
      model.refresh()
      contactsModel.refresh()
      // Pick up hand-edits to config.toml (the file header invites them),
      // but never discard the user's own unsaved changes.
      if !settingsModel.isDirty {
        settingsModel.reload()
      }
    }
    .task {
      await permissionModel.refresh()
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
      fullDiskAccessRow
      restartRow
    }
  }

  /// Surfaces the daemon's own `chat.db` open(2) probe so users can spot when
  /// FDA needs a refresh (typical after `make daemon-install` rebuilds the
  /// binary's inode/cdhash). The probe runs in the daemon at startup and
  /// every minute thereafter; we just render its result.
  @ViewBuilder
  private var fullDiskAccessRow: some View {
    HStack {
      Text("Full Disk Access")
        .frame(width: 180, alignment: .leading)

      if model.status == .down {
        // No probe is running when the daemon is unreachable — saying
        // "Probing…" here sent users chasing a permission that wasn't
        // the problem (fresh installs have no daemon at all).
        Label("Daemon not running — start imu-watcher to verify", systemImage: "info.circle")
          .foregroundStyle(.secondary)
          .font(.callout)
          .lineLimit(2)
      } else {
      switch model.statusInfo?.chatDBReadable {
      case .some(true):
        Label("Granted — daemon can read chat.db", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.callout)
          .lineLimit(2)
      case .some(false):
        Label("Denied — open(2) on chat.db fails", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.callout)
          .lineLimit(2)
      case .none:
        Label("Probing…", systemImage: "hourglass")
          .foregroundStyle(.secondary)
          .font(.callout)
      }
      }

      Spacer()

      Button {
        model.refresh()
      } label: {
        Label("Recheck", systemImage: "arrow.clockwise")
      }
      .help("Re-fetch the daemon's chat.db probe. The daemon also re-probes automatically each minute.")

      Button {
        revealDaemonBinaryInFinder()
      } label: {
        Label("Reveal binary", systemImage: "magnifyingglass")
      }
      .help("Opens Finder at the imu-watcher binary so you can drag it into the Full Disk Access list.")

      if model.status != .down && model.statusInfo?.chatDBReadable != true {
        Button("Open Full Disk Access…") {
          openFullDiskAccessSettings()
        }
        .help("Opens System Settings → Privacy & Security → Full Disk Access. After a rebuild macOS revokes the grant; drag the daemon binary in or toggle the existing entry off and back on.")
      }
    }
  }

  private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
      NSWorkspace.shared.open(url)
    }
  }

  /// Opens Finder with the daemon binary selected so the user can drag it
  /// straight into the Full Disk Access list — saves a manual cd dance.
  private func revealDaemonBinaryInFinder() {
    let binDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("imessage-unsent", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)
    let bin = binDir.appendingPathComponent("imu-watcher", isDirectory: false)
    if FileManager.default.fileExists(atPath: bin.path) {
      NSWorkspace.shared.activateFileViewerSelecting([bin])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([binDir])
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
      permissionRow

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
        .accessibilityLabel("Notification preview length")
        .accessibilityValue("\(settingsModel.draft.notifications.previewChars) characters")
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
        if SettingsNotifications.isInsecureWebhookURL(settingsModel.draft.notifications.webhook) {
          Label(
            "Plain HTTP — recovered message text would leave this Mac unencrypted. Use https://.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Webhook signing secret")
          .font(.callout)
        SecureField(
          "(used to HMAC-sign webhook requests)",
          text: $settingsModel.draft.notifications.webhookSigningSecret
        )
        .textFieldStyle(.roundedBorder)
        Text("Stored in plaintext in config.toml (owner-only file permissions).")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Contacts

  private var contactsSection: some View {
    Section("Contacts") {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Address Book access")
          Spacer()
          Text(contactsModel.statusText)
            .foregroundStyle(.secondary)
            .monospacedDigit()
          if contactsModel.isRequesting {
            ProgressView().controlSize(.small)
          } else if contactsModel.promptSuppressed || contactsModel.status == .denied {
            Button("Open System Settings") {
              NSWorkspace.shared.open(ContactsPermissionModel.systemSettingsURL)
            }
            .help("macOS won't show the prompt again. Allow iMessage Unsent under Privacy → Contacts.")
          } else {
            switch contactsModel.status {
            case .notDetermined:
              Button("Enable Contacts") {
                Task { await contactsModel.enable() }
              }
            case .authorized:
              HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
                Button("Validate") { contactsModel.sampleLookup() }
                  .help("Reads the first contact from your Address Book to confirm name resolution is working.")
              }
            default:
              EmptyView()
            }
          }
        }
        if contactsModel.promptSuppressed {
          Text("macOS suppressed the prompt — open System Settings → Privacy → Contacts to allow.")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if let result = contactsModel.lastTestResult {
          switch result {
          case let .sample(name, source):
            Label("Resolved \(name) (\(source))", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.green)
          case .empty:
            Label("Address Book is empty — can't validate.", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
        Text("Used to render display names + avatars on recovered messages. Read-only; no contact data leaves your Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
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

  // MARK: Notification permission

  @ViewBuilder
  private var permissionRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("macOS notification permission")
        Spacer()
        Text(permissionModel.statusText)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        if permissionModel.isRequesting {
          ProgressView().controlSize(.small)
          Text("Requesting…")
            .foregroundStyle(.secondary)
            .font(.caption)
        } else if permissionModel.promptSuppressed || permissionModel.status == .denied {
          Button("Open System Settings") {
            NSWorkspace.shared.open(NotificationPermissionModel.systemSettingsURL)
          }
          .help("macOS won't show the permission prompt again. Allow imessage-unsent in System Settings → Notifications.")
        } else {
          switch permissionModel.status {
          case .notDetermined:
            Button("Enable notifications") {
              Task { await permissionModel.enable() }
            }
          case .authorized, .provisional:
            HStack(spacing: 6) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Button("Send test") {
                permissionModel.sendTestNotification()
              }
              .help("Posts a benign banner so you can confirm notifications reach the user.")
            }
          default:
            EmptyView()
          }
        }
      }
      if permissionModel.promptSuppressed {
        Text("macOS suppressed the prompt — likely because notifications were declined previously. Open System Settings to allow.")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let result = permissionModel.lastTestResult {
        switch result {
        case .sent:
          Label("Test notification sent", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        case let .failed(message):
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        }
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
