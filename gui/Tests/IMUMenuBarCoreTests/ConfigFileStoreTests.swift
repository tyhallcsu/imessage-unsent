import Foundation
import XCTest
@testable import IMUMenuBarCore

final class ConfigFileStoreTests: XCTestCase {
  private var workDir: URL!

  override func setUpWithError() throws {
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-cfs-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let workDir { try? FileManager.default.removeItem(at: workDir) }
    workDir = nil
  }

  func testLoadReturnsDefaultsWhenFileMissing() {
    let store = ConfigFileStore(configURL: workDir.appendingPathComponent("none.toml"))
    let config = store.load()
    XCTAssertEqual(config, SettingsConfig())
  }

  func testParsesAllFieldsFromDaemonFormat() {
    let toml = """
    # daemon config
    log_level = "debug"
    data_dir = "~/Library/Application Support/imessage-unsent-test"
    archive_retention = 25

    [notifications]
    show = false
    preview_chars = 20
    webhook = "https://example.test/hook"
    webhook_signing_secret = "secret"
    ignored = "value"

    [experimental]
    restore_mode = true
    """
    let parsed = ConfigFileStore.parse(toml)

    XCTAssertEqual(parsed.logLevel, "debug")
    XCTAssertEqual(parsed.dataDir, "~/Library/Application Support/imessage-unsent-test")
    XCTAssertEqual(parsed.archiveRetention, 25)
    XCTAssertEqual(parsed.notifications.show, false)
    XCTAssertEqual(parsed.notifications.previewChars, 20)
    XCTAssertEqual(parsed.notifications.webhook, "https://example.test/hook")
    XCTAssertEqual(parsed.notifications.webhookSigningSecret, "secret")
    XCTAssertTrue(parsed.experimental.restoreMode)
  }

  func testSerializeRoundTripsAllFields() {
    let original = SettingsConfig(
      logLevel: "warn",
      dataDir: "/tmp/imu",
      archiveRetention: 250,
      notifications: SettingsNotifications(
        show: true,
        previewChars: 120,
        webhook: "https://example.test/imu",
        webhookSigningSecret: "with \"quote\" and \\backslash"
      ),
      experimental: SettingsExperimental(restoreMode: true)
    )

    let text = ConfigFileStore.serialize(original)
    let parsed = ConfigFileStore.parse(text)

    XCTAssertEqual(parsed, original)
  }

  func testPreviewCharsIsClampedTo0To200() {
    XCTAssertEqual(ConfigFileStore.parse("""
    [notifications]
    preview_chars = -10
    """).notifications.previewChars, 0)

    XCTAssertEqual(ConfigFileStore.parse("""
    [notifications]
    preview_chars = 9999
    """).notifications.previewChars, 200)
  }

  func testSaveCreatesParentDirectoryAndPersists() throws {
    let nested = workDir
      .appendingPathComponent("a/b/c/.config/imessage-unsent", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
    let store = ConfigFileStore(configURL: nested)
    let config = SettingsConfig(
      logLevel: "warn",
      notifications: SettingsNotifications(show: false, previewChars: 42)
    )

    try store.save(config)

    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    let reloaded = ConfigFileStore(configURL: nested).load()
    XCTAssertEqual(reloaded, config)
  }

  func testSaveOverwritesExistingFile() throws {
    let url = workDir.appendingPathComponent("config.toml")
    let store = ConfigFileStore(configURL: url)
    try store.save(SettingsConfig(archiveRetention: 10))
    try store.save(SettingsConfig(archiveRetention: 100))

    XCTAssertEqual(store.load().archiveRetention, 100)
  }

  func testDefaultGUIConfigURLLandsUnderDotConfig() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    XCTAssertEqual(
      defaultGUIConfigURL(home: home).path,
      "/Users/example/.config/imessage-unsent/config.toml"
    )
  }
}

extension ConfigFileStoreTests {
  func testSaveWritesOwnerOnlyFilePermissions() throws {
    // config.toml carries the webhook signing secret in plaintext — the
    // saved file must be 0600 even though atomic writes replace the inode.
    let url = workDir.appendingPathComponent("perms.toml")
    let store = ConfigFileStore(configURL: url)
    var config = SettingsConfig()
    config.notifications.webhookSigningSecret = "not-a-real-secret"

    try store.save(config)

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    XCTAssertEqual(mode & 0o777, 0o600)
  }
}

extension ConfigFileStoreTests {
  func testHashInsideQuotedValueSurvivesRoundTrip() {
    var config = SettingsConfig()
    config.notifications.webhookSigningSecret = "abc#def#ghi"
    config.notifications.webhook = "https://example.com/hook#fragment"

    let reparsed = ConfigFileStore.parse(ConfigFileStore.serialize(config))

    XCTAssertEqual(reparsed.notifications.webhookSigningSecret, "abc#def#ghi")
    XCTAssertEqual(reparsed.notifications.webhook, "https://example.com/hook#fragment")
    XCTAssertEqual(reparsed, config)
  }

  func testCommentsOutsideQuotesAreStillStripped() {
    let toml = """
    log_level = "debug"  # trailing comment
    [notifications]
    webhook = "https://example.com/a#b" # another comment
    """
    let parsed = ConfigFileStore.parse(toml)
    XCTAssertEqual(parsed.logLevel, "debug")
    XCTAssertEqual(parsed.notifications.webhook, "https://example.com/a#b")
  }
}
