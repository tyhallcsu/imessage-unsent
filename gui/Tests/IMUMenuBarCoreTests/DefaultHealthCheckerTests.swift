import Foundation
import UserNotifications
import XCTest
@testable import IMUMenuBarCore

final class DefaultHealthCheckerTests: XCTestCase {
  // MARK: All-pass

  func testAllPass_whenEverythingPresent() async {
    let env = TestEnvironment.allHealthy()
    let checks = await env.checker.runAll()
    let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })

    XCTAssertEqual(byID["daemon.binary"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.plist"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.launchctl"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.scripts"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.running"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.status"]?.severity, .pass)
    XCTAssertEqual(byID["fda.granted"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.fda"]?.severity, .pass)
    XCTAssertEqual(byID["data.dir"]?.severity, .pass)
    XCTAssertEqual(byID["archive.dir"]?.severity, .pass)
    XCTAssertEqual(byID["socket.exists"]?.severity, .pass)
    XCTAssertEqual(byID["config.file"]?.severity, .pass)
    XCTAssertEqual(byID["notifications"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.log"]?.severity, .info)

    XCTAssertEqual(env.launchctl.lastQueriedTarget, "gui/501/com.imu.watcher",
                   "checker must thread the launchctl service target through to the probe")
  }

  // MARK: Specific failure modes

  func testMissingBinary_isFail_andRemediationContainsMakeDaemonInstall() async {
    let env = TestEnvironment.allHealthy()
    env.files.presentURLs.remove(env.paths.daemonBinary.path)
    env.files.executableURLs.remove(env.paths.daemonBinary.path)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.binary" })

    XCTAssertEqual(row.severity, .fail)
    XCTAssertTrue(row.remediation?.contains("make daemon-install") ?? false,
                  "remediation should point at make daemon-install, got: \(String(describing: row.remediation))")
  }

  func testBinaryPresentButNotExecutable_isWarn() async {
    let env = TestEnvironment.allHealthy()
    env.files.executableURLs.remove(env.paths.daemonBinary.path)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.binary" })

    XCTAssertEqual(row.severity, .warn)
  }

  func testDaemonPingFails_butFileChecksUnaffected() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.pingResult = false
    env.daemon.statusResult = nil

    let checks = await env.checker.runAll()
    let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })

    XCTAssertEqual(byID["daemon.running"]?.severity, .fail)
    XCTAssertEqual(byID["daemon.binary"]?.severity, .pass, "filesystem check should be independent of ping")
    XCTAssertEqual(byID["daemon.plist"]?.severity, .pass)
    XCTAssertEqual(byID["daemon.scripts"]?.severity, .pass)
  }

  func testFDAMissing_isFail_withSystemSettingsURL() async {
    let env = TestEnvironment.allHealthy()
    env.files.presentURLs.remove(env.paths.chatDB.path)
    env.files.presentURLs.remove(env.paths.chatDBWal.path)
    // Messages directory itself stays visible — the FAIL branch.

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "fda.granted" })

    XCTAssertEqual(row.severity, .fail)
    XCTAssertEqual(row.remediationURL?.scheme, "x-apple.systempreferences")
  }

  func testFDAInconclusive_whenChatDBAndMessagesDirBothUnobservable() async {
    let env = TestEnvironment.allHealthy()
    env.files.presentURLs.remove(env.paths.chatDB.path)
    env.files.presentURLs.remove(env.paths.chatDBWal.path)
    env.files.presentURLs.remove(env.paths.chatDB.deletingLastPathComponent().path)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "fda.granted" })

    XCTAssertEqual(row.severity, .warn)
    XCTAssertTrue(row.detail?.contains("daemon's logs") ?? false || row.detail?.contains("daemon") ?? false)
  }

  func testNotificationsDenied_isFail() async {
    let env = TestEnvironment.allHealthy()
    env.notifications.cannedStatus = .denied

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "notifications" })

    XCTAssertEqual(row.severity, .fail)
  }

  func testNotificationsNotDetermined_isWarn() async {
    let env = TestEnvironment.allHealthy()
    env.notifications.cannedStatus = .notDetermined

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "notifications" })

    XCTAssertEqual(row.severity, .warn)
  }

  func testConfigMissing_isInfo_notFail() async {
    let env = TestEnvironment.allHealthy()
    env.configLoaderResult = nil

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "config.file" })

    XCTAssertEqual(row.severity, .info)
  }

  func testConfigDataDirOverride_redirectsArchivesAndSocketChecks() async {
    let env = TestEnvironment.allHealthy()
    let customDataDir = env.paths.home.appendingPathComponent("custom-imu-data", isDirectory: true)
    let customArchives = customDataDir.appendingPathComponent("archives", isDirectory: true)
    let customSocket = customDataDir.appendingPathComponent("daemon.sock", isDirectory: false)

    var override = SettingsConfig()
    override.dataDir = "~/custom-imu-data"
    env.configLoaderResult = override

    // Default paths NOT present; the overridden ones ARE.
    env.files.presentURLs.remove(env.paths.archivesDir.path)
    env.files.presentURLs.remove(env.paths.socketURL.path)
    env.files.presentURLs.remove(env.paths.dataDir.path)

    env.files.presentURLs.insert(customDataDir.path)
    env.files.writableURLs.insert(customDataDir.path)
    env.files.presentURLs.insert(customArchives.path)
    env.files.presentURLs.insert(customSocket.path)

    let checks = await env.checker.runAll()
    let byID = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, $0) })

    XCTAssertEqual(byID["data.dir"]?.severity, .pass,
                   "checker must probe the user-overridden data_dir, not the hardcoded default")
    XCTAssertEqual(byID["archive.dir"]?.severity, .pass)
    XCTAssertEqual(byID["socket.exists"]?.severity, .pass)
  }

  func testStatusLastError_isWarn() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.statusResult = DaemonStatusInfo(
      state: "watching",
      version: "0.4.1",
      startedAt: "2026-05-02T12:00:00Z",
      uptimeSeconds: 3600,
      lastWalChangeAt: nil,
      lastWalSize: 0,
      recoveryCount: 0,
      lastError: "WAL read failed: EPERM",
      dataDir: env.paths.dataDir.path,
      notificationsShow: true
    )

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.status" })

    XCTAssertEqual(row.severity, .warn)
    XCTAssertTrue(row.summary.contains("WAL read failed"))
  }

  func testStatusCalledOnlyOncePerRun() async {
    let env = TestEnvironment.allHealthy()
    _ = await env.checker.runAll()
    XCTAssertEqual(env.daemon.statusCallCount, 1, "runAll() must cache the daemon status() call")
    XCTAssertEqual(env.daemon.pingCallCount, 1, "runAll() must cache the daemon ping() call")
  }

  func testSocketMissingButDaemonUp_isWarn() async {
    let env = TestEnvironment.allHealthy()
    env.files.presentURLs.remove(env.paths.socketURL.path)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "socket.exists" })

    XCTAssertEqual(row.severity, .warn)
  }

  func testSocketMissingAndDaemonDown_isInfo() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.pingResult = false
    env.daemon.statusResult = nil
    env.files.presentURLs.remove(env.paths.socketURL.path)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "socket.exists" })

    XCTAssertEqual(row.severity, .info)
  }

  func testArchiveDirMissing_isWarn() async {
    let env = TestEnvironment.allHealthy()
    env.files.presentURLs.remove(env.paths.archivesDir.path)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "archive.dir" })

    XCTAssertEqual(row.severity, .warn)
  }

  // MARK: launchctl probe

  func testLaunchctlNotFound_isFail_withBootstrapRemediation() async {
    let env = TestEnvironment.allHealthy()
    env.launchctl.cannedResult = .notFound

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.launchctl" })

    XCTAssertEqual(row.severity, .fail)
    XCTAssertTrue(row.remediation?.contains("launchctl bootstrap") ?? false,
                  "remediation should point at launchctl bootstrap, got: \(String(describing: row.remediation))")
    XCTAssertTrue(row.remediation?.contains("make daemon-install") ?? false)
  }

  func testLaunchctlLoadedAndRunning_isPass_withPidInSummary() async {
    let env = TestEnvironment.allHealthy()
    env.launchctl.cannedResult = .loaded(state: "running", pid: 8421, lastExitCode: 0)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.launchctl" })

    XCTAssertEqual(row.severity, .pass)
    XCTAssertTrue(row.summary.contains("8421"), "pid should appear in summary, got: \(row.summary)")
  }

  func testLaunchctlLoadedButCrashed_isFail_withKickstartRemediation() async {
    let env = TestEnvironment.allHealthy()
    env.launchctl.cannedResult = .loaded(state: "not running", pid: nil, lastExitCode: 1)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.launchctl" })

    XCTAssertEqual(row.severity, .fail,
                   "non-zero last exit code should be fail, not warn — the daemon crashed")
    XCTAssertTrue(row.summary.contains("last exit code 1"),
                  "summary should surface the exit code, got: \(row.summary)")
    XCTAssertTrue(row.remediation?.contains("launchctl kickstart") ?? false)
  }

  func testLaunchctlLoadedButWaiting_isWarn_whenExitCodeZero() async {
    let env = TestEnvironment.allHealthy()
    env.launchctl.cannedResult = .loaded(state: "waiting", pid: nil, lastExitCode: nil)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.launchctl" })

    XCTAssertEqual(row.severity, .warn,
                   "waiting with no error history is a transient state, not a hard failure")
  }

  func testLaunchctlError_isWarn_withTruncatedStderrInDetail() async {
    let env = TestEnvironment.allHealthy()
    let longStderr = String(repeating: "x", count: 500)
    env.launchctl.cannedResult = .error(stderr: longStderr, exitCode: 99)

    let checks = await env.checker.runAll()
    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.launchctl" })

    XCTAssertEqual(row.severity, .warn)
    XCTAssertTrue(row.summary.contains("99"), "exit code should appear in summary")
    XCTAssertTrue((row.detail ?? "").contains("…"), "long stderr should be truncated with an ellipsis")
  }

  // MARK: - daemon.fda (issue #59 follow-up)

  func testDaemonFDA_isPass_whenChatDBReadableTrue() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.statusResult = DaemonStatusInfo(
      state: "watching",
      version: "0.4.1",
      startedAt: "2026-05-02T12:00:00Z",
      uptimeSeconds: 3600,
      lastWalChangeAt: "2026-05-02T12:30:00Z",
      lastWalSize: 65_536,
      recoveryCount: 4,
      lastError: nil,
      dataDir: env.paths.dataDir.path,
      notificationsShow: true,
      chatDBReadable: true,
      chatDBProbedAt: "2026-05-02T13:00:00Z"
    )
    let checks = await env.checker.runAll()

    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.fda" })
    XCTAssertEqual(row.severity, .pass)
    XCTAssertTrue(row.summary.contains("can open"))
  }

  func testDaemonFDA_isFail_whenChatDBReadableFalse_withSettingsURL() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.statusResult = DaemonStatusInfo(
      state: "watching",
      version: "0.4.1",
      startedAt: "2026-05-02T12:00:00Z",
      uptimeSeconds: 3600,
      lastWalChangeAt: nil,
      lastWalSize: 0,
      recoveryCount: 0,
      lastError: "failed to open chat.db read-only: authorization denied",
      dataDir: env.paths.dataDir.path,
      notificationsShow: true,
      chatDBReadable: false,
      chatDBProbedAt: "2026-05-02T13:00:00Z"
    )
    let checks = await env.checker.runAll()

    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.fda" })
    XCTAssertEqual(row.severity, .fail)
    XCTAssertTrue(row.summary.contains("denied"))
    XCTAssertEqual(row.remediationURL?.scheme, "x-apple.systempreferences")
  }

  func testDaemonFDA_isInfo_whenChatDBReadableNil() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.statusResult = DaemonStatusInfo(
      state: "watching",
      version: "0.4.1",
      startedAt: "2026-05-02T12:00:00Z",
      uptimeSeconds: 30,  // freshly started, hasn't probed yet
      lastWalChangeAt: nil,
      lastWalSize: 0,
      recoveryCount: 0,
      lastError: nil,
      dataDir: env.paths.dataDir.path,
      notificationsShow: true,
      chatDBReadable: nil,
      chatDBProbedAt: nil
    )
    let checks = await env.checker.runAll()

    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.fda" })
    XCTAssertEqual(row.severity, .info)
    XCTAssertTrue(row.summary.contains("not yet probed"))
  }

  func testDaemonFDA_isInfo_whenDaemonNotReachable() async {
    let env = TestEnvironment.allHealthy()
    env.daemon.pingResult = false
    env.daemon.statusResult = nil
    let checks = await env.checker.runAll()

    let row = try! XCTUnwrap(checks.first { $0.id == "daemon.fda" })
    XCTAssertEqual(row.severity, .info)
    XCTAssertTrue(row.summary.contains("Daemon not reachable"))
  }

  func testLaunchctlServiceTargetIncludesUid() {
    // Spot-check the default helper so a future refactor doesn't silently drop
    // the uid component of the launchctl service target.
    let target = DefaultHealthChecker.defaultLaunchctlServiceTarget(uid: 501)
    XCTAssertEqual(target, "gui/501/com.imu.watcher")
  }
}

// MARK: - Test helpers

private final class ConfigHolder {
  var value: SettingsConfig?
  init(_ value: SettingsConfig?) { self.value = value }
}

private final class TestEnvironment {
  let paths: HealthCheckPaths
  let files: StubFileProbing
  let daemon: StubDaemonControlClient
  let notifications: StubNotificationProbe
  let launchctl: StubLaunchctlProbe
  private let configHolder: ConfigHolder
  let checker: DefaultHealthChecker

  var configLoaderResult: SettingsConfig? {
    get { configHolder.value }
    set { configHolder.value = newValue }
  }

  init(
    paths: HealthCheckPaths,
    files: StubFileProbing,
    daemon: StubDaemonControlClient,
    notifications: StubNotificationProbe,
    launchctl: StubLaunchctlProbe,
    initialConfig: SettingsConfig?
  ) {
    self.paths = paths
    self.files = files
    self.daemon = daemon
    self.notifications = notifications
    self.launchctl = launchctl
    let holder = ConfigHolder(initialConfig)
    self.configHolder = holder
    self.checker = DefaultHealthChecker(
      paths: paths,
      daemon: daemon,
      files: files,
      notifications: notifications,
      launchctl: launchctl,
      launchctlServiceTarget: "gui/501/com.imu.watcher",
      configLoader: { _ in holder.value }
    )
  }

  static func allHealthy() -> TestEnvironment {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    let paths = HealthCheckPaths.defaults(home: home)

    let files = StubFileProbing()
    files.presentURLs.formUnion([
      paths.daemonBinary.path,
      paths.launchAgentPlist.path,
      paths.recoveryScript.path,
      paths.dataDir.path,
      paths.archivesDir.path,
      paths.socketURL.path,
      paths.logFile.path,
      paths.configFile.path,
      paths.chatDB.path,
      paths.chatDBWal.path,
      paths.chatDB.deletingLastPathComponent().path
    ])
    files.executableURLs.insert(paths.daemonBinary.path)
    files.writableURLs.insert(paths.dataDir.path)
    files.attrs[paths.daemonBinary.path] = [.size: NSNumber(value: 524_288)]
    files.attrs[paths.logFile.path] = [.size: NSNumber(value: 4096)]
    files.dirContents[paths.archivesDir.path] = [
      paths.archivesDir.appendingPathComponent("entry-1", isDirectory: true),
      paths.archivesDir.appendingPathComponent("entry-2", isDirectory: true)
    ]

    let daemon = StubDaemonControlClient()
    daemon.pingResult = true
    daemon.statusResult = DaemonStatusInfo(
      state: "watching",
      version: "0.4.1",
      startedAt: "2026-05-02T12:00:00Z",
      uptimeSeconds: 3600,
      lastWalChangeAt: "2026-05-02T12:30:00Z",
      lastWalSize: 65_536,
      recoveryCount: 4,
      lastError: nil,
      dataDir: paths.dataDir.path,
      notificationsShow: true,
      chatDBReadable: true,
      chatDBProbedAt: "2026-05-02T13:00:00Z"
    )

    let notifications = StubNotificationProbe()
    notifications.cannedStatus = .authorized

    let launchctl = StubLaunchctlProbe()
    launchctl.cannedResult = .loaded(state: "running", pid: 12_345, lastExitCode: 0)

    return TestEnvironment(
      paths: paths,
      files: files,
      daemon: daemon,
      notifications: notifications,
      launchctl: launchctl,
      initialConfig: SettingsConfig()
    )
  }
}

private final class StubFileProbing: FileProbing {
  var presentURLs: Set<String> = []
  var executableURLs: Set<String> = []
  var writableURLs: Set<String> = []
  var attrs: [String: [FileAttributeKey: Any]] = [:]
  var dirContents: [String: [URL]] = [:]

  func exists(_ url: URL) -> Bool { presentURLs.contains(url.path) }
  func isExecutable(_ url: URL) -> Bool { executableURLs.contains(url.path) }
  func isWritable(_ url: URL) -> Bool { writableURLs.contains(url.path) }
  func attributes(_ url: URL) -> [FileAttributeKey: Any]? { attrs[url.path] }
  func contentsOfDirectory(_ url: URL) -> [URL] { dirContents[url.path] ?? [] }
}

final class StubDaemonControlClient: DaemonControlClienting {
  var pingResult: Bool = true
  var statusResult: DaemonStatusInfo?
  var recentResult: [ArchiveHistoryEntryDTO] = []
  var deleteResult: Bool = true

  private(set) var pingCallCount = 0
  private(set) var statusCallCount = 0
  private(set) var recentCallCount = 0
  private(set) var deleteCallCount = 0

  func ping() -> Bool {
    pingCallCount += 1
    return pingResult
  }

  func status() -> DaemonStatusInfo? {
    statusCallCount += 1
    return statusResult
  }

  func recent(limit _: Int) -> [ArchiveHistoryEntryDTO] {
    recentCallCount += 1
    return recentResult
  }

  func delete(id _: String) -> Bool {
    deleteCallCount += 1
    return deleteResult
  }
}

final class StubNotificationProbe: NotificationPermissionProbing {
  var cannedStatus: UNAuthorizationStatus = .authorized

  func authorizationStatus() async -> UNAuthorizationStatus {
    cannedStatus
  }
}

final class StubLaunchctlProbe: LaunchctlProbing {
  var cannedResult: LaunchctlPrintResult = .loaded(state: "running", pid: 1, lastExitCode: 0)
  private(set) var lastQueriedTarget: String?

  func print(serviceTarget: String) -> LaunchctlPrintResult {
    lastQueriedTarget = serviceTarget
    return cannedResult
  }
}
