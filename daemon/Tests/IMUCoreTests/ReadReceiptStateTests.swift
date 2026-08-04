import XCTest
@testable import IMUCore

/// The receipt model behind issue #163. `chat.db` stores the flag and the
/// timestamp independently, so "was it read before the unsend?" has three
/// possible answers, not two — and one of them is "we cannot tell".
final class ReadReceiptStateTests: XCTestCase {
  func testClassifyPrefersTimestampOverFlag() {
    XCTAssertEqual(ReadReceiptState.classify(flag: true, timestamp: 797_000_000_000_000_000), .timestamped)
    // A timestamp without the flag still means it happened.
    XCTAssertEqual(ReadReceiptState.classify(flag: false, timestamp: 797_000_000_000_000_000), .timestamped)
    XCTAssertEqual(ReadReceiptState.classify(flag: true, timestamp: 0), .flaggedOnly)
    XCTAssertEqual(ReadReceiptState.classify(flag: false, timestamp: 0), .none)
  }

  func testNormalizeUpconvertsLegacySecondPrecision() {
    XCTAssertEqual(normalizeAppleTimestamp(797_000_000), 797_000_000_000_000_000)
    XCTAssertEqual(normalizeAppleTimestamp(797_000_000_000_000_000), 797_000_000_000_000_000)
    XCTAssertEqual(normalizeAppleTimestamp(0), 0)
  }

  func testReadBeforeRetractionWhenReadFirst() {
    let edited: Int64 = 797_000_010_000_000_000
    let context = RetractionReadContext(
      isRead: true,
      dateRead: 797_000_008_200_000_000,
      isDelivered: true,
      dateDelivered: 797_000_000_000_000_000,
      editedAt: edited
    )
    XCTAssertEqual(context.readState, .timestamped)
    XCTAssertEqual(context.readBeforeRetraction, true)
    XCTAssertEqual(try XCTUnwrap(context.readToRetractSeconds), 1.8, accuracy: 0.0001)
  }

  func testReadAfterRetractionIsNotReadBefore() {
    // 54 of 83 real retracted rows look like this: the read receipt lands on
    // the tombstone, after the sender already pulled the message back.
    let context = RetractionReadContext(
      isRead: true,
      dateRead: 797_000_020_000_000_000,
      isDelivered: true,
      dateDelivered: 797_000_000_000_000_000,
      editedAt: 797_000_010_000_000_000
    )
    XCTAssertEqual(context.readBeforeRetraction, false)
    XCTAssertEqual(try XCTUnwrap(context.readToRetractSeconds), -10, accuracy: 0.0001)
  }

  func testIdenticalTimestampsAreNotEvidenceOfReadingFirst() {
    let stamp: Int64 = 797_000_010_000_000_000
    let context = RetractionReadContext(
      isRead: true,
      dateRead: stamp,
      isDelivered: true,
      dateDelivered: stamp,
      editedAt: stamp
    )
    XCTAssertEqual(context.readBeforeRetraction, false)
  }

  func testFlaggedOnlyCannotBeOrderedAgainstTheRetraction() {
    let context = RetractionReadContext(
      isRead: true,
      dateRead: 0,
      isDelivered: true,
      dateDelivered: 0,
      editedAt: 797_000_010_000_000_000
    )
    XCTAssertEqual(context.readState, .flaggedOnly)
    XCTAssertEqual(context.deliveredState, .flaggedOnly)
    // Read, but with no time there is no ordering to claim.
    XCTAssertNil(context.readBeforeRetraction)
    XCTAssertNil(context.readToRetractSeconds)
  }

  func testUnreadRowHasNoOrdering() {
    let context = RetractionReadContext(
      isRead: false,
      dateRead: 0,
      isDelivered: true,
      dateDelivered: 797_000_000_000_000_000,
      editedAt: 797_000_010_000_000_000
    )
    XCTAssertEqual(context.readState, .none)
    XCTAssertEqual(context.deliveredState, .timestamped)
    XCTAssertNil(context.readBeforeRetraction)
  }

  func testLegacySecondPrecisionRowsStillOrderCorrectly() {
    // Both columns come from the same database, so both are seconds.
    let context = RetractionReadContext(
      isRead: true,
      dateRead: 797_000_008,
      isDelivered: true,
      dateDelivered: 797_000_000,
      editedAt: 797_000_010
    )
    XCTAssertEqual(context.readBeforeRetraction, true)
    XCTAssertEqual(try XCTUnwrap(context.readToRetractSeconds), 2, accuracy: 0.0001)
  }

  func testJSONKeysMatchTheManifestContract() throws {
    let context = RetractionReadContext(
      isRead: true,
      dateRead: 797_000_008_200_000_000,
      isDelivered: true,
      dateDelivered: 797_000_000_000_000_000,
      editedAt: 797_000_010_000_000_000
    )
    let data = try JSONEncoder().encode(context)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(object["read_state"] as? String, "timestamped")
    XCTAssertEqual(object["delivered_state"] as? String, "timestamped")
    XCTAssertEqual(object["read_before_retraction"] as? Bool, true)
    XCTAssertNotNil(object["read_to_retract_seconds"])
    XCTAssertNotNil(object["date_read"])

    let round = try JSONDecoder().decode(RetractionReadContext.self, from: data)
    XCTAssertEqual(round, context)
  }
}
