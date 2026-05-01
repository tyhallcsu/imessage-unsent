import XCTest
@testable import IMUCore

final class EventFilterTests: XCTestCase {
  func testDenyListWinsAndAllowListRestrictsWhenPresent() {
    let event = RetractionEvent(rowid: 1, guid: "guid", handle: "+15551234567", editedAt: 1)

    XCTAssertTrue(EventFilter(allow: [], deny: []).allows(event))
    XCTAssertFalse(EventFilter(allow: [], deny: ["+15551234567"]).allows(event))
    XCTAssertTrue(EventFilter(allow: ["+15551234567"], deny: []).allows(event))
    XCTAssertFalse(EventFilter(allow: ["+15557654321"], deny: []).allows(event))
    XCTAssertFalse(EventFilter(allow: ["+15551234567"], deny: ["+15551234567"]).allows(event))
  }
}
