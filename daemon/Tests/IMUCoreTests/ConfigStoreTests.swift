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
  }

  func testExpandsTildeRelativeToHome() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      expandTilde("~/Library/Application Support/imessage-unsent", home: home).path,
      "/Users/example/Library/Application Support/imessage-unsent"
    )
  }
}
