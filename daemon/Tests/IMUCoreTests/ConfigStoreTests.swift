import Foundation
import XCTest
@testable import IMUCore

final class ConfigStoreTests: XCTestCase {
  func testDefaultsWhenConfigIsMissing() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)

    let config = try ConfigStore(url: url).load()

    XCTAssertEqual(config.logLevel, "info")
    XCTAssertEqual(config.dataDir, "~/Library/Application Support/imessage-unsent")
    XCTAssertEqual(config.experimental.restoreMode, false, "restore_mode must default to false (Notify-only)")
  }

  func testParsesLogLevelAndDataDir() {
    let config = ConfigStore.parse(
      """
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
      """
    )

    XCTAssertEqual(config.logLevel, "debug")
    XCTAssertEqual(config.dataDir, "~/Library/Application Support/imessage-unsent-test")
    XCTAssertEqual(config.archiveRetention, 25)
    XCTAssertEqual(config.notifications.show, false)
    XCTAssertEqual(config.notifications.previewChars, 20)
    XCTAssertEqual(config.notifications.webhook, "https://example.test/hook")
    XCTAssertEqual(config.notifications.webhookSigningSecret, "secret")
    XCTAssertEqual(config.experimental.restoreMode, false, "absent [experimental] section must keep the safe default")
  }

  func testExpandsTildeRelativeToHome() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      expandTilde("~/Library/Application Support/imessage-unsent", home: home).path,
      "/Users/example/Library/Application Support/imessage-unsent"
    )
  }

  func testExperimentalSectionIsParsedAndDefaultsRetainedWhenAbsent() {
    let configOptIn = ConfigStore.parse(
      """
      log_level = "info"

      [experimental]
      restore_mode = true
      """
    )
    XCTAssertTrue(configOptIn.experimental.restoreMode)

    let configExplicitOff = ConfigStore.parse(
      """
      [experimental]
      restore_mode = false
      """
    )
    XCTAssertFalse(configExplicitOff.experimental.restoreMode)

    let configNoSection = ConfigStore.parse(
      """
      log_level = "warn"
      """
    )
    XCTAssertFalse(
      configNoSection.experimental.restoreMode,
      "missing [experimental] section must NOT silently enable Restore mode"
    )
  }

  func testExperimentalSectionRejectsNonBoolValues() {
    let config = ConfigStore.parse(
      """
      [experimental]
      restore_mode = "definitely yes"
      """
    )
    XCTAssertFalse(
      config.experimental.restoreMode,
      "non-boolean restore_mode values must fall back to the safe default"
    )
  }

  func testSerializeRoundTripsAllFields() {
    let original = DaemonConfig(
      logLevel: "debug",
      dataDir: "~/Library/Application Support/imessage-unsent-test",
      archiveRetention: 250,
      notifications: NotificationConfig(
        show: false,
        previewChars: 120,
        webhook: "https://example.test/hook?token=abc",
        webhookSigningSecret: "s3cret-with-\"quote\"-and-\\backslash"
      ),
      experimental: ExperimentalConfig(restoreMode: true)
    )

    let text = ConfigStore.serialize(original)
    let parsed = ConfigStore.parse(text)

    XCTAssertEqual(parsed, original)
  }

  func testSerializeIsIdempotent() {
    let original = DaemonConfig(
      notifications: NotificationConfig(show: true, previewChars: 80)
    )
    let first = ConfigStore.serialize(original)
    let second = ConfigStore.serialize(ConfigStore.parse(first))
    XCTAssertEqual(first, second, "serialize → parse → serialize must be a fixed point")
  }

  func testSaveCreatesParentDirectoryAndPersistsConfig() throws {
    let workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nested = workDir.appendingPathComponent("nested/.config/imessage-unsent", isDirectory: true)
    let url = nested.appendingPathComponent("config.toml", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let store = ConfigStore(url: url)
    let config = DaemonConfig(
      logLevel: "warn",
      notifications: NotificationConfig(show: false, previewChars: 42)
    )
    try store.save(config)

    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    let loaded = try store.load()
    XCTAssertEqual(loaded, config)
  }
}
