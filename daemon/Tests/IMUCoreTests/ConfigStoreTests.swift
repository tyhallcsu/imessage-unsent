import XCTest
@testable import IMUCore

final class ConfigStoreTests: XCTestCase {
  func testConfigRoundTrip() throws {
    var config = DaemonConfig()
    config.notificationPreviewChars = 0
    config.retentionLimit = 10
    config.filterAllow = ["+15551234567"]

    let rendered = ConfigStore.render(config)
    let parsed = ConfigStore.parse(rendered)

    XCTAssertEqual(parsed.notificationPreviewChars, 0)
    XCTAssertEqual(parsed.retentionLimit, 10)
    XCTAssertEqual(parsed.filterAllow, ["+15551234567"])
    XCTAssertFalse(parsed.restoreMode)
  }
}
