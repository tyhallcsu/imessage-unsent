import XCTest
@testable import IMUCore

final class RecoveryFailureCategoryTests: XCTestCase {
  func testRoundTripsThroughJSON() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for category in RecoveryFailureCategory.allCases {
      let encoded = try encoder.encode(category)
      let decoded = try decoder.decode(RecoveryFailureCategory.self, from: encoded)
      XCTAssertEqual(decoded, category)
    }
  }

  func testRawValuesAreSnakeCase() {
    XCTAssertEqual(RecoveryFailureCategory.walCheckpointed.rawValue, "wal_checkpointed")
    XCTAssertEqual(RecoveryFailureCategory.unknownHandle.rawValue, "unknown_handle")
    XCTAssertEqual(RecoveryFailureCategory.notInLocalWAL.rawValue, "not_in_local_wal")
    XCTAssertEqual(RecoveryFailureCategory.attachmentOnly.rawValue, "attachment_only")
    XCTAssertEqual(RecoveryFailureCategory.scriptError.rawValue, "script_error")
    XCTAssertEqual(RecoveryFailureCategory.unknown.rawValue, "unknown")
  }

  func testEveryCaseHasNonEmptyDisplayMessage() {
    for category in RecoveryFailureCategory.allCases {
      XCTAssertFalse(category.displayMessage.isEmpty, "\(category) is missing a displayMessage")
    }
  }

  func testActionableHintExistsForAllExceptUnknown() {
    for category in RecoveryFailureCategory.allCases where category != .unknown {
      XCTAssertNotNil(category.actionableHint, "\(category) is missing an actionableHint")
      XCTAssertFalse(category.actionableHint!.isEmpty)
    }
    XCTAssertNil(RecoveryFailureCategory.unknown.actionableHint)
  }

  func testDecodesFromExternalJSONShape() throws {
    struct Wrapper: Codable {
      let failureCategory: RecoveryFailureCategory
      enum CodingKeys: String, CodingKey { case failureCategory = "failure_category" }
    }
    let json = #"{"failure_category": "wal_checkpointed"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Wrapper.self, from: json)
    XCTAssertEqual(decoded.failureCategory, .walCheckpointed)
  }

  func testDecodingUnknownStringFails() {
    let json = #""bogus_value""#.data(using: .utf8)!
    XCTAssertThrowsError(try JSONDecoder().decode(RecoveryFailureCategory.self, from: json))
  }
}
