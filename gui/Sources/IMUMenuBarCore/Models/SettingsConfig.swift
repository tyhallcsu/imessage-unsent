import Foundation

/// Mirror of the daemon's `DaemonConfig` for the subset the menu bar settings
/// pane edits or displays. Field names and TOML keys match the daemon's parser
/// so round-trips between the two are lossless.
public struct SettingsConfig: Equatable {
  public var logLevel: String
  public var dataDir: String
  public var archiveRetention: Int
  public var notifications: SettingsNotifications
  public var experimental: SettingsExperimental

  public init(
    logLevel: String = "info",
    dataDir: String = "~/Library/Application Support/imessage-unsent",
    archiveRetention: Int = 100,
    notifications: SettingsNotifications = SettingsNotifications(),
    experimental: SettingsExperimental = SettingsExperimental()
  ) {
    self.logLevel = logLevel
    self.dataDir = dataDir
    self.archiveRetention = archiveRetention
    self.notifications = notifications
    self.experimental = experimental
  }
}

public struct SettingsNotifications: Equatable {
  public var show: Bool
  public var previewChars: Int
  public var webhook: String
  public var webhookSigningSecret: String

  public init(
    show: Bool = true,
    previewChars: Int = 80,
    webhook: String = "",
    webhookSigningSecret: String = ""
  ) {
    self.show = show
    self.previewChars = previewChars
    self.webhook = webhook
    self.webhookSigningSecret = webhookSigningSecret
  }
}

public struct SettingsExperimental: Equatable {
  /// Read-only mirror of the daemon's `experimental.restore_mode`. The GUI
  /// surfaces this as a status indicator only; toggling it from the UI is
  /// gated behind the consent flow tracked in issue #16.
  public var restoreMode: Bool

  public init(restoreMode: Bool = false) {
    self.restoreMode = restoreMode
  }
}

/// Allowed values for `archive_retention` exposed in the dropdown UI.
public let settingsRetentionChoices: [Int] = [10, 50, 100, 250, 1000]
