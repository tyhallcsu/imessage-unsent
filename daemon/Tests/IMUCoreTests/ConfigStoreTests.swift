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
}
