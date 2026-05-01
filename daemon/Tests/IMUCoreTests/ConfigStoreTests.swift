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
      ignored = "value"
      """
    )

    XCTAssertEqual(config.logLevel, "debug")
    XCTAssertEqual(config.dataDir, "~/Library/Application Support/imessage-unsent-test")
    XCTAssertEqual(config.archiveRetention, 25)
  }

  func testExpandsTildeRelativeToHome() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      expandTilde("~/Library/Application Support/imessage-unsent", home: home).path,
      "/Users/example/Library/Application Support/imessage-unsent"
    )
  }
}
