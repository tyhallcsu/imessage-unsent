import XCTest
@testable import IMUMenuBarCore

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

  func testRawValuesMatchDaemonContract() {
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
    }
    XCTAssertNil(RecoveryFailureCategory.unknown.actionableHint)
  }
}

extension RecoveryFailureCategoryTests {
  /// Issue #160 — the GUI mirror must carry `predates_monitoring` with the exact
  /// raw value the daemon writes, or the manifest decodes as `.unknown` and the
  /// user is told "cause not determined" for a case we understand perfectly well.
  /// The daemon-side assertion lives in IMUCoreTests; neither package can import
  /// the other, so the contract needs a test on both sides.
  func testPredatesMonitoringMirrorsTheDaemonRawValue() {
    XCTAssertEqual(RecoveryFailureCategory.predatesMonitoring.rawValue, "predates_monitoring")
    XCTAssertEqual(
      RecoveryFailureCategory(rawValue: "predates_monitoring"),
      .predatesMonitoring
    )
    XCTAssertTrue(RecoveryFailureCategory.allCases.contains(.predatesMonitoring))
    XCTAssertNotEqual(
      RecoveryFailureCategory.predatesMonitoring.displayMessage,
      RecoveryFailureCategory.walCheckpointed.displayMessage
    )
    XCTAssertNotNil(RecoveryFailureCategory.predatesMonitoring.actionableHint)
  }
}
