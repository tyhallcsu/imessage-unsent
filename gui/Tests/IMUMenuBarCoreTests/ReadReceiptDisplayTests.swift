import Foundation
import XCTest
@testable import IMUMenuBarCore

/// Issue #163 — how the detail view describes "did I see it before they
/// unsent it?".
///
/// The rule under test is that the GUI never claims more than the manifest
/// supports: a flag without a timestamp cannot be ordered against the
/// retraction, and an archive with no receipt block is *unknown*, not *no*.
final class ReadReceiptDisplayTests: XCTestCase {
  private var workDir: URL!

  override func setUpWithError() throws {
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-rr-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let workDir { try? FileManager.default.removeItem(at: workDir) }
    workDir = nil
  }

  // MARK: - Summary wording

  func testReadBeforeRetractionStatesTheGap() {
    let receipt = RecoveryReadReceipt(
      readState: .timestamped,
      deliveredState: .timestamped,
      readBeforeRetraction: true,
      readToRetractSeconds: 1.8
    )
    XCTAssertEqual(receipt.summary, "Yes — you read it 1.8s before it was unsent")
    XCTAssertEqual(receipt.deliverySummary, "Delivered")
  }

  func testReadAfterRetractionSaysItWasThePlaceholder() {
    let receipt = RecoveryReadReceipt(
      readState: .timestamped,
      deliveredState: .timestamped,
      readBeforeRetraction: false,
      readToRetractSeconds: -10
    )
    XCTAssertTrue(receipt.summary.hasPrefix("No —"))
    XCTAssertTrue(receipt.summary.contains("placeholder"))
  }

  func testFlaggedOnlyRefusesToOrderTheEvents() {
    let receipt = RecoveryReadReceipt(
      readState: .flaggedOnly,
      deliveredState: .flaggedOnly,
      readBeforeRetraction: nil,
      readToRetractSeconds: nil
    )
    XCTAssertTrue(receipt.summary.contains("never recorded"))
    XCTAssertTrue(receipt.summary.contains("can't tell"))
    // Must not assert either direction.
    XCTAssertFalse(receipt.summary.hasPrefix("Yes"))
    XCTAssertFalse(receipt.summary.hasPrefix("No"))
    XCTAssertEqual(receipt.deliverySummary, "Delivered (time not recorded)")
  }

  func testUnreadRowSaysNo() {
    let receipt = RecoveryReadReceipt(
      readState: .none,
      deliveredState: .none,
      readBeforeRetraction: nil,
      readToRetractSeconds: nil
    )
    XCTAssertEqual(receipt.summary, "No — the message was never marked read")
    XCTAssertEqual(receipt.deliverySummary, "No delivery receipt")
  }

  func testDurationFormattingScalesWithMagnitude() {
    XCTAssertEqual(RecoveryReadReceipt.formatDuration(1.8), "1.8s")
    XCTAssertEqual(RecoveryReadReceipt.formatDuration(-1.8), "1.8s")
    XCTAssertEqual(RecoveryReadReceipt.formatDuration(120), "2.0 min")
    XCTAssertEqual(RecoveryReadReceipt.formatDuration(7_200), "2.0 h")
    XCTAssertEqual(RecoveryReadReceipt.formatDuration(172_800), "2.0 d")
  }

  // MARK: - Loading

  func testLoaderReadsTheReceiptBlock() throws {
    let archive = try writeArchive(
      name: "2026-08-03T120000Z-401",
      readReceipt: [
        "read_state": "timestamped",
        "delivered_state": "timestamped",
        "date_read": 797_000_008_200_000_000,
        "date_delivered": 797_000_000_000_000_000,
        "read_before_retraction": true,
        "read_to_retract_seconds": 1.8
      ]
    )

    let detail = try FileSystemRecoveryDetailLoader().load(archiveDir: archive)
    let receipt = try XCTUnwrap(detail.readReceipt)
    XCTAssertEqual(receipt.readState, .timestamped)
    XCTAssertEqual(receipt.readBeforeRetraction, true)
    XCTAssertEqual(try XCTUnwrap(receipt.readToRetractSeconds), 1.8, accuracy: 0.0001)
  }

  func testArchiveWithoutReceiptBlockLoadsAsUnknown() throws {
    let archive = try writeArchive(name: "2026-08-03T120100Z-402", readReceipt: nil)

    let detail = try FileSystemRecoveryDetailLoader().load(archiveDir: archive)
    // nil is the signal the view turns into "Unknown" — it must not decode as
    // a `.none` receipt, which would read as "was not read".
    XCTAssertNil(detail.readReceipt)
  }

  func testPartialReceiptBlockDegradesInsteadOfFailingTheManifest() throws {
    // A block with only some keys must not throw the whole manifest decode.
    let archive = try writeArchive(
      name: "2026-08-03T120200Z-403",
      readReceipt: ["read_state": "flagged_only"]
    )

    let detail = try FileSystemRecoveryDetailLoader().load(archiveDir: archive)
    let receipt = try XCTUnwrap(detail.readReceipt)
    XCTAssertEqual(receipt.readState, .flaggedOnly)
    XCTAssertEqual(receipt.deliveredState, .none)
    XCTAssertNil(receipt.readBeforeRetraction)
  }

  func testUnrecognizedStateFallsBackInsteadOfCrashing() throws {
    let archive = try writeArchive(
      name: "2026-08-03T120300Z-404",
      readReceipt: ["read_state": "some_future_state"]
    )

    let detail = try FileSystemRecoveryDetailLoader().load(archiveDir: archive)
    XCTAssertEqual(try XCTUnwrap(detail.readReceipt).readState, .none)
  }

  // MARK: - Helpers

  private func writeArchive(name: String, readReceipt: [String: Any]?) throws -> URL {
    let archive = workDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)

    var manifest: [String: Any] = [
      "detected_at": "2026-08-03T12:00:00.000Z",
      "rowid": 401,
      "guid": "guid-401",
      "handle": "+15550001000",
      "edited_at": 797_000_010_000_000_000,
      "snapshot_started_at": "2026-08-03T12:00:00.000Z",
      "snapshot_finished_at": "2026-08-03T12:00:00.500Z",
      "snap_files": ["chat.db-wal": ["present": true]]
    ]
    if let readReceipt {
      manifest["read_receipt"] = readReceipt
    }

    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try data.write(to: archive.appendingPathComponent("manifest.json", isDirectory: false))
    return archive
  }
}
