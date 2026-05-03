import Foundation
import UserNotifications

// MARK: - Paths

/// Where each App Doctor probe looks. Defaults match the install paths used by
/// `scripts/install-daemon.sh` and the GUI's `defaultDaemonSocketURL` /
/// `defaultGUIConfigURL` helpers. Tests construct one against a temp `home`.
public struct HealthCheckPaths: Sendable {
  public var home: URL
  public var daemonBinary: URL
  public var launchAgentPlist: URL
  public var recoveryScript: URL
  public var dataDir: URL
  public var archivesDir: URL
  public var socketURL: URL
  public var logFile: URL
  public var configFile: URL
  public var chatDB: URL
  public var chatDBWal: URL

  public init(
    home: URL,
    daemonBinary: URL,
    launchAgentPlist: URL,
    recoveryScript: URL,
    dataDir: URL,
    archivesDir: URL,
    socketURL: URL,
    logFile: URL,
    configFile: URL,
    chatDB: URL,
    chatDBWal: URL
  ) {
    self.home = home
    self.daemonBinary = daemonBinary
    self.launchAgentPlist = launchAgentPlist
    self.recoveryScript = recoveryScript
    self.dataDir = dataDir
    self.archivesDir = archivesDir
    self.socketURL = socketURL
    self.logFile = logFile
    self.configFile = configFile
    self.chatDB = chatDB
    self.chatDBWal = chatDBWal
  }

  public static func defaults(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> HealthCheckPaths {
    let appSupport = home
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("imessage-unsent", isDirectory: true)
    let messages = home
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Messages", isDirectory: true)
    return HealthCheckPaths(
      home: home,
      daemonBinary: appSupport
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("imu-watcher", isDirectory: false),
      launchAgentPlist: home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
        .appendingPathComponent("com.imu.watcher.plist", isDirectory: false),
      recoveryScript: appSupport
        .appendingPathComponent("scripts", isDirectory: true)
        .appendingPathComponent("recover.sh", isDirectory: false),
      dataDir: appSupport,
      archivesDir: appSupport.appendingPathComponent("archives", isDirectory: true),
      socketURL: appSupport.appendingPathComponent("daemon.sock", isDirectory: false),
      logFile: home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("imessage-unsent", isDirectory: true)
        .appendingPathComponent("watcher.log", isDirectory: false),
      configFile: defaultGUIConfigURL(home: home),
      chatDB: messages.appendingPathComponent("chat.db", isDirectory: false),
      chatDBWal: messages.appendingPathComponent("chat.db-wal", isDirectory: false)
    )
  }

  /// Returns a copy with `dataDir` / `archivesDir` / `socketURL` redirected to
  /// the path declared in the user's `config.toml`. Tilde paths expand against
  /// the receiver's `home`. A nil/empty override returns `self` unchanged.
  public func overriding(dataDir override: String?) -> HealthCheckPaths {
    let trimmed = override?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !trimmed.isEmpty else { return self }
    let expanded: URL
    if trimmed == "~" {
      expanded = home
    } else if trimmed.hasPrefix("~/") {
      expanded = home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true)
    } else if trimmed.hasPrefix("/") {
      expanded = URL(fileURLWithPath: trimmed, isDirectory: true)
    } else {
      expanded = home.appendingPathComponent(trimmed, isDirectory: true)
    }
    if expanded.standardizedFileURL == dataDir.standardizedFileURL {
      return self
    }
    var copy = self
    copy.dataDir = expanded
    copy.archivesDir = expanded.appendingPathComponent("archives", isDirectory: true)
    copy.socketURL = expanded.appendingPathComponent("daemon.sock", isDirectory: false)
    return copy
  }
}

// MARK: - File probing

public protocol FileProbing {
  func exists(_ url: URL) -> Bool
  func isExecutable(_ url: URL) -> Bool
  func isWritable(_ url: URL) -> Bool
  func attributes(_ url: URL) -> [FileAttributeKey: Any]?
  func contentsOfDirectory(_ url: URL) -> [URL]
}

public struct DefaultFileProbe: FileProbing {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func exists(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
  }

  public func isExecutable(_ url: URL) -> Bool {
    fileManager.isExecutableFile(atPath: url.path)
  }

  public func isWritable(_ url: URL) -> Bool {
    fileManager.isWritableFile(atPath: url.path)
  }

  public func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
    try? fileManager.attributesOfItem(atPath: url.path)
  }

  public func contentsOfDirectory(_ url: URL) -> [URL] {
    (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
  }
}

// MARK: - Notification permission probing

public protocol NotificationPermissionProbing {
  func authorizationStatus() async -> UNAuthorizationStatus
}

public struct DefaultNotificationProbe: NotificationPermissionProbing {
  public init() {}

  public func authorizationStatus() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus)
      }
    }
  }
}

// MARK: - Checker

public protocol HealthChecking {
  func runAll() async -> [HealthCheck]
}

/// Runs the full battery of App Doctor checks against the local install. All
/// dependencies are injectable: tests pass stubs that never touch
/// `~/Library/Messages`, the daemon socket, or `UNUserNotificationCenter`.
public final class DefaultHealthChecker: HealthChecking {
  public let paths: HealthCheckPaths
  private let daemon: DaemonControlClienting
  private let files: FileProbing
  private let notifications: NotificationPermissionProbing
  private let configLoader: (URL) -> SettingsConfig?

  public init(
    paths: HealthCheckPaths = .defaults(),
    daemon: DaemonControlClienting,
    files: FileProbing = DefaultFileProbe(),
    notifications: NotificationPermissionProbing = DefaultNotificationProbe(),
    configLoader: @escaping (URL) -> SettingsConfig? = DefaultHealthChecker.defaultConfigLoader
  ) {
    self.paths = paths
    self.daemon = daemon
    self.files = files
    self.notifications = notifications
    self.configLoader = configLoader
  }

  /// Reads `~/.config/imessage-unsent/config.toml` if it exists; returns nil
  /// otherwise (so the `config.file` check can report "using defaults").
  public static let defaultConfigLoader: (URL) -> SettingsConfig? = { url in
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path),
          let text = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    return ConfigFileStore.parse(text)
  }

  public func runAll() async -> [HealthCheck] {
    // Cache the daemon round-trips: at most one ping + one status per run.
    let pong = daemon.ping()
    let status = pong ? daemon.status() : nil
    let parsedConfig = configLoader(paths.configFile)
    let configMissing = parsedConfig == nil
    let resolved = paths.overriding(dataDir: parsedConfig?.dataDir)
    let notifStatus = await notifications.authorizationStatus()

    var checks: [HealthCheck] = []
    checks.append(checkDaemonBinary(paths: resolved))
    checks.append(checkDaemonPlist(paths: resolved))
    checks.append(checkRecoveryScripts(paths: resolved))
    checks.append(checkDaemonRunning(paths: resolved, pong: pong))
    checks.append(checkDaemonStatus(status: status, pong: pong))
    checks.append(checkFullDiskAccess(paths: resolved))
    checks.append(checkDataDir(paths: resolved))
    checks.append(checkArchiveDir(paths: resolved))
    checks.append(checkSocketExists(paths: resolved, pong: pong))
    checks.append(checkConfigFile(paths: resolved, parsed: parsedConfig, missing: configMissing))
    checks.append(checkNotifications(status: notifStatus))
    checks.append(checkDaemonLog(paths: resolved))
    return checks
  }

  // MARK: - Individual checks

  private func checkDaemonBinary(paths: HealthCheckPaths) -> HealthCheck {
    let url = paths.daemonBinary
    if !files.exists(url) {
      return HealthCheck(
        id: "daemon.binary",
        category: .daemon,
        order: 0,
        severity: .fail,
        title: "Daemon binary",
        summary: "Not installed at \(displayPath(url, home: paths.home))",
        detail: "The `imu-watcher` binary is missing. Until it is installed, the daemon cannot run and no recoveries will be archived.",
        remediation: "Run `make daemon-install` from the repo to build and install the watcher binary.",
        remediationURL: nil
      )
    }
    if !files.isExecutable(url) {
      return HealthCheck(
        id: "daemon.binary",
        category: .daemon,
        order: 0,
        severity: .warn,
        title: "Daemon binary",
        summary: "Present but not executable",
        detail: "The watcher binary at \(url.path) lacks the executable bit, so launchd will not be able to spawn it.",
        remediation: "Run `chmod +x \(url.path)` or reinstall via `make daemon-install`.",
        remediationURL: nil
      )
    }
    let size = (files.attributes(url)?[.size] as? NSNumber)?.intValue ?? 0
    return HealthCheck(
      id: "daemon.binary",
      category: .daemon,
      order: 0,
      severity: .pass,
      title: "Daemon binary",
      summary: "Installed and executable (\(formatBytes(size)))",
      detail: url.path,
      remediation: nil,
      remediationURL: nil
    )
  }

  private func checkDaemonPlist(paths: HealthCheckPaths) -> HealthCheck {
    let url = paths.launchAgentPlist
    if files.exists(url) {
      return HealthCheck(
        id: "daemon.plist",
        category: .daemon,
        order: 1,
        severity: .pass,
        title: "LaunchAgent plist",
        summary: "Installed at \(displayPath(url, home: paths.home))",
        detail: nil,
        remediation: nil,
        remediationURL: nil
      )
    }
    return HealthCheck(
      id: "daemon.plist",
      category: .daemon,
      order: 1,
      severity: .fail,
      title: "LaunchAgent plist",
      summary: "Missing — daemon will not start at login",
      detail: "Expected at \(url.path).",
      remediation: "Run `make daemon-install` to install the plist and bootstrap the LaunchAgent.",
      remediationURL: nil
    )
  }

  private func checkRecoveryScripts(paths: HealthCheckPaths) -> HealthCheck {
    let url = paths.recoveryScript
    if files.exists(url) {
      return HealthCheck(
        id: "daemon.scripts",
        category: .daemon,
        order: 2,
        severity: .pass,
        title: "Recovery scripts",
        summary: "Installed at \(displayPath(url.deletingLastPathComponent(), home: paths.home))",
        detail: url.path,
        remediation: nil,
        remediationURL: nil
      )
    }
    return HealthCheck(
      id: "daemon.scripts",
      category: .daemon,
      order: 2,
      severity: .warn,
      title: "Recovery scripts",
      summary: "`recover.sh` not found — daemon cannot run recoveries",
      detail: "Expected at \(url.path). The daemon shells out to this script when it detects a retraction.",
      remediation: "Run `make daemon-install` to copy the recovery scripts into place.",
      remediationURL: nil
    )
  }

  private func checkDaemonRunning(paths: HealthCheckPaths, pong: Bool) -> HealthCheck {
    if pong {
      return HealthCheck(
        id: "daemon.running",
        category: .daemon,
        order: 3,
        severity: .pass,
        title: "Daemon running",
        summary: "Control socket responded to ping",
        detail: "Socket: \(paths.socketURL.path)",
        remediation: nil,
        remediationURL: nil
      )
    }
    let logURL = paths.logFile
    return HealthCheck(
      id: "daemon.running",
      category: .daemon,
      order: 3,
      severity: .fail,
      title: "Daemon running",
      summary: "Control socket did not respond",
      detail: "The watcher daemon is either not running or its control socket at \(paths.socketURL.path) is unreachable.",
      remediation: "Try `launchctl kickstart -k gui/$(id -u)/com.imu.watcher`. If that fails, check \(logURL.path) and confirm Full Disk Access for `imu-watcher`.",
      remediationURL: files.exists(logURL) ? logURL : nil
    )
  }

  private func checkDaemonStatus(status: DaemonStatusInfo?, pong: Bool) -> HealthCheck {
    guard let status else {
      return HealthCheck(
        id: "daemon.status",
        category: .daemon,
        order: 4,
        severity: pong ? .warn : .info,
        title: "Daemon status",
        summary: pong ? "Ping ok but status query failed" : "Not available — daemon is down",
        detail: pong ? "The daemon responded to ping but did not return a status payload. This usually means the daemon is mid-restart." : "See `daemon.running` for remediation.",
        remediation: nil,
        remediationURL: nil
      )
    }
    let uptime = formatDuration(seconds: status.uptimeSeconds)
    let summary: String
    let severity: HealthSeverity
    let detail: String
    if let lastError = status.lastError, !lastError.isEmpty {
      severity = .warn
      summary = "Reporting an error: \(lastError)"
      detail = """
        Version: \(status.version)
        State: \(status.state)
        Uptime: \(uptime)
        Recoveries observed: \(status.recoveryCount)
        Last error: \(lastError)
        """
    } else {
      severity = .pass
      summary = "v\(status.version) — \(uptime), \(status.recoveryCount) recoveries observed"
      detail = """
        Version: \(status.version)
        State: \(status.state)
        Uptime: \(uptime)
        Recoveries observed: \(status.recoveryCount)
        Data dir: \(status.dataDir)
        Notifications: \(status.notificationsShow ? "on" : "off")
        """
    }
    return HealthCheck(
      id: "daemon.status",
      category: .daemon,
      order: 4,
      severity: severity,
      title: "Daemon status",
      summary: summary,
      detail: detail,
      remediation: severity == .warn ? "If the error persists, open System Settings → Privacy & Security → Full Disk Access and confirm `imu-watcher` is enabled. Then restart the daemon with `launchctl kickstart -k gui/$(id -u)/com.imu.watcher`." : nil,
      remediationURL: nil
    )
  }

  private func checkFullDiskAccess(paths: HealthCheckPaths) -> HealthCheck {
    let chatDB = paths.chatDB
    let walURL = paths.chatDBWal
    let messagesDir = chatDB.deletingLastPathComponent()
    let dbVisible = files.exists(chatDB)
    let walVisible = files.exists(walURL)
    let messagesVisible = files.exists(messagesDir)
    let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    if dbVisible {
      return HealthCheck(
        id: "fda.granted",
        category: .permissions,
        order: 0,
        severity: .pass,
        title: "Full Disk Access",
        summary: "`chat.db` is visible to this process",
        detail: "Heuristic check — visibility from the GUI process is a strong indicator that the daemon also has Full Disk Access. The daemon's own logs are still authoritative.",
        remediation: nil,
        remediationURL: nil
      )
    }
    if !messagesVisible && !walVisible {
      return HealthCheck(
        id: "fda.granted",
        category: .permissions,
        order: 0,
        severity: .warn,
        title: "Full Disk Access",
        summary: "Inconclusive — `~/Library/Messages` is not visible to this process",
        detail: "The GUI process may itself lack Full Disk Access, in which case this row is expected and the daemon's logs (\(paths.logFile.path)) are authoritative. Grant FDA to `imu-watcher` (not the GUI) for the daemon to read `chat.db`.",
        remediation: "Open System Settings → Privacy & Security → Full Disk Access and add `imu-watcher` from \(paths.daemonBinary.path).",
        remediationURL: settingsURL
      )
    }
    return HealthCheck(
      id: "fda.granted",
      category: .permissions,
      order: 0,
      severity: .fail,
      title: "Full Disk Access",
      summary: "`chat.db` is not visible — Full Disk Access likely missing",
      detail: "`~/Library/Messages` exists but `chat.db` is unreadable, which usually means Full Disk Access has not been granted to `imu-watcher`. Without it, the daemon cannot detect retractions.",
      remediation: "Open System Settings → Privacy & Security → Full Disk Access and add `imu-watcher` from \(paths.daemonBinary.path).",
      remediationURL: settingsURL
    )
  }

  private func checkDataDir(paths: HealthCheckPaths) -> HealthCheck {
    let url = paths.dataDir
    if !files.exists(url) {
      return HealthCheck(
        id: "data.dir",
        category: .storage,
        order: 0,
        severity: .fail,
        title: "Data directory",
        summary: "Missing at \(displayPath(url, home: paths.home))",
        detail: "The daemon writes archives, the control socket, and the detector state under this directory.",
        remediation: "Run `make daemon-install` to create it.",
        remediationURL: nil
      )
    }
    if !files.isWritable(url) {
      return HealthCheck(
        id: "data.dir",
        category: .storage,
        order: 0,
        severity: .warn,
        title: "Data directory",
        summary: "Exists but not writable",
        detail: "Path: \(url.path)",
        remediation: "Check the directory permissions (expected `0o700` owned by the current user).",
        remediationURL: url
      )
    }
    return HealthCheck(
      id: "data.dir",
      category: .storage,
      order: 0,
      severity: .pass,
      title: "Data directory",
      summary: "Writable at \(displayPath(url, home: paths.home))",
      detail: url.path,
      remediation: nil,
      remediationURL: url
    )
  }

  private func checkArchiveDir(paths: HealthCheckPaths) -> HealthCheck {
    let url = paths.archivesDir
    if !files.exists(url) {
      return HealthCheck(
        id: "archive.dir",
        category: .storage,
        order: 1,
        severity: .warn,
        title: "Archive directory",
        summary: "Not yet created",
        detail: "Expected at \(url.path). The daemon creates this on its first recovery, so this is informational unless it persists.",
        remediation: nil,
        remediationURL: nil
      )
    }
    let entryCount = files.contentsOfDirectory(url).count
    return HealthCheck(
      id: "archive.dir",
      category: .storage,
      order: 1,
      severity: .pass,
      title: "Archive directory",
      summary: "\(entryCount) \(entryCount == 1 ? "entry" : "entries") at \(displayPath(url, home: paths.home))",
      detail: url.path,
      remediation: nil,
      remediationURL: url
    )
  }

  private func checkSocketExists(paths: HealthCheckPaths, pong: Bool) -> HealthCheck {
    let url = paths.socketURL
    let exists = files.exists(url)
    if exists {
      return HealthCheck(
        id: "socket.exists",
        category: .storage,
        order: 2,
        severity: .pass,
        title: "Control socket",
        summary: "Present at \(displayPath(url, home: paths.home))",
        detail: nil,
        remediation: nil,
        remediationURL: nil
      )
    }
    if !pong {
      return HealthCheck(
        id: "socket.exists",
        category: .storage,
        order: 2,
        severity: .info,
        title: "Control socket",
        summary: "Not present — expected while daemon is down",
        detail: "The daemon recreates the socket on startup. See `daemon.running`.",
        remediation: nil,
        remediationURL: nil
      )
    }
    return HealthCheck(
      id: "socket.exists",
      category: .storage,
      order: 2,
      severity: .warn,
      title: "Control socket",
      summary: "Daemon is up but the socket file is missing — unusual",
      detail: "The ping succeeded, but `\(url.path)` does not exist. This usually means another process is holding the socket or the path differs from the daemon's actual configuration.",
      remediation: "Restart the daemon with `launchctl kickstart -k gui/$(id -u)/com.imu.watcher`.",
      remediationURL: nil
    )
  }

  private func checkConfigFile(
    paths: HealthCheckPaths,
    parsed: SettingsConfig?,
    missing: Bool
  ) -> HealthCheck {
    let url = paths.configFile
    if missing {
      return HealthCheck(
        id: "config.file",
        category: .config,
        order: 0,
        severity: .info,
        title: "Config file",
        summary: "Not present — daemon is using defaults",
        detail: "Expected at \(url.path). Save the Settings pane to write a config, or create the file by hand.",
        remediation: nil,
        remediationURL: url.deletingLastPathComponent()
      )
    }
    guard let parsed else {
      return HealthCheck(
        id: "config.file",
        category: .config,
        order: 0,
        severity: .warn,
        title: "Config file",
        summary: "Present but not parseable",
        detail: "The TOML at \(url.path) could not be parsed. Until it is fixed, the daemon will fall back to defaults.",
        remediation: "Open the file to inspect, or delete it to fall back to defaults.",
        remediationURL: url
      )
    }
    let detail = """
      Path: \(url.path)
      log_level: \(parsed.logLevel)
      data_dir: \(parsed.dataDir)
      archive_retention: \(parsed.archiveRetention)
      notifications.show: \(parsed.notifications.show)
      experimental.restore_mode: \(parsed.experimental.restoreMode)
      """
    return HealthCheck(
      id: "config.file",
      category: .config,
      order: 0,
      severity: .pass,
      title: "Config file",
      summary: "Loaded from \(displayPath(url, home: paths.home))",
      detail: detail,
      remediation: nil,
      remediationURL: url
    )
  }

  private func checkNotifications(status: UNAuthorizationStatus) -> HealthCheck {
    let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    switch status {
    case .authorized:
      return HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .pass,
        title: "Notifications",
        summary: "Authorized",
        detail: "macOS will deliver retraction notifications when the daemon emits them.",
        remediation: nil,
        remediationURL: nil
      )
    case .provisional:
      return HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .pass,
        title: "Notifications",
        summary: "Provisional — quiet delivery only",
        detail: "Notifications will appear silently in Notification Center until the user explicitly grants the permission.",
        remediation: "Open System Settings → Notifications to upgrade to standard delivery.",
        remediationURL: settingsURL
      )
    case .notDetermined:
      return HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .warn,
        title: "Notifications",
        summary: "Permission has not been requested yet",
        detail: "Until the daemon requests notification permission, recovery alerts are silently dropped.",
        remediation: "Trigger a test notification from the daemon, or open System Settings → Notifications and enable `imessage-unsent` manually.",
        remediationURL: settingsURL
      )
    case .denied:
      return HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .fail,
        title: "Notifications",
        summary: "Denied — recovery alerts will not appear",
        detail: "macOS will silently drop notifications from `imessage-unsent` until permission is granted.",
        remediation: "Open System Settings → Notifications and allow notifications for `imessage-unsent`.",
        remediationURL: settingsURL
      )
    case .ephemeral:
      return HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .warn,
        title: "Notifications",
        summary: "Ephemeral — App Clip session",
        detail: "Notification permission applies only for the current session.",
        remediation: nil,
        remediationURL: settingsURL
      )
    @unknown default:
      return HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .info,
        title: "Notifications",
        summary: "Status unknown (UNAuthorizationStatus = \(status.rawValue))",
        detail: nil,
        remediation: nil,
        remediationURL: settingsURL
      )
    }
  }

  private func checkDaemonLog(paths: HealthCheckPaths) -> HealthCheck {
    let url = paths.logFile
    if !files.exists(url) {
      return HealthCheck(
        id: "daemon.log",
        category: .logs,
        order: 0,
        severity: .info,
        title: "Daemon log",
        summary: "Not yet created",
        detail: "Expected at \(url.path). The daemon writes here once it has started.",
        remediation: nil,
        remediationURL: nil
      )
    }
    let size = (files.attributes(url)?[.size] as? NSNumber)?.intValue ?? 0
    return HealthCheck(
      id: "daemon.log",
      category: .logs,
      order: 0,
      severity: .info,
      title: "Daemon log",
      summary: "\(formatBytes(size)) at \(displayPath(url, home: paths.home))",
      detail: url.path,
      remediation: "Open Log",
      remediationURL: url
    )
  }
}

// MARK: - Helpers

private func displayPath(_ url: URL, home: URL) -> String {
  let homePath = home.path
  let urlPath = url.path
  if urlPath == homePath { return "~" }
  if urlPath.hasPrefix(homePath + "/") {
    return "~" + urlPath.dropFirst(homePath.count)
  }
  return urlPath
}

private func formatBytes(_ bytes: Int) -> String {
  let formatter = ByteCountFormatter()
  formatter.allowedUnits = [.useKB, .useMB, .useGB]
  formatter.countStyle = .file
  return formatter.string(fromByteCount: Int64(bytes))
}

private func formatDuration(seconds: Int) -> String {
  let formatter = DateComponentsFormatter()
  formatter.allowedUnits = [.day, .hour, .minute, .second]
  formatter.unitsStyle = .abbreviated
  formatter.maximumUnitCount = 2
  return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
}
