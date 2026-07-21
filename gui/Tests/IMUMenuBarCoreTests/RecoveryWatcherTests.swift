import Foundation
import XCTest
@testable import IMUMenuBarCore

/// First direct coverage of the GUI-side notification watcher (#149 / G-4):
/// banner bodies must honor the Settings "Preview length" privacy setting
/// (0 = no recovered text in notifications) instead of a hardcoded 120.
@MainActor
final class RecoveryWatcherTests: XCTestCase {
  private var workDir: URL!
  private var archivesDir: URL!

  override func setUpWithError() throws {
    workDir = URL(
      fileURLWithPath: "/private/tmp/imu-rw-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    archivesDir = workDir.appendingPathComponent("archives", isDirectory: true)
    try FileManager.default.createDirectory(at: archivesDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let workDir {
      try? FileManager.default.removeItem(at: workDir)
    }
    workDir = nil
    archivesDir = nil
  }

  private func writeArchive(name: String, handle: String, text: String) throws {
    let dir = archivesDir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["handle": handle, "rowid": 1]
    try JSONSerialization.data(withJSONObject: manifest)
      .write(to: dir.appendingPathComponent("manifest.json"))
    let recovery: [String: Any] = [
      "recovered": ["text_b64": Data(text.utf8).base64EncodedString()]
    ]
    try JSONSerialization.data(withJSONObject: recovery)
      .write(to: dir.appendingPathComponent("recovery.json"))
  }

  private func makeWatcher(
    previewChars: @escaping () -> Int,
    capturing drafts: NSMutableArray
  ) -> RecoveryWatcher {
    RecoveryWatcher(
      archivesDir: archivesDir,
      isEnabled: { true },
      previewChars: previewChars,
      notifier: { drafts.add($0) }
    )
  }

  func testBannerBodyIsTruncatedToThePreviewSetting() throws {
    let drafts = NSMutableArray()
    let watcher = makeWatcher(previewChars: { 10 }, capturing: drafts)
    watcher.pollOnce()  // seeds the high-water mark on the empty dir

    try writeArchive(
      name: "2026-04-30T120000Z-101",
      handle: "+15550001000",
      text: "This synthetic recovered message is far longer than ten characters."
    )
    watcher.pollOnce()

    XCTAssertEqual(drafts.count, 1)
    let draft = try XCTUnwrap(drafts.firstObject as? RecoveryNotificationDraft)
    XCTAssertEqual(draft.body, "This synth")
    XCTAssertTrue(draft.recovered)
  }

  func testPreviewZeroKeepsRecoveredTextOutOfTheBanner() throws {
    let drafts = NSMutableArray()
    let watcher = makeWatcher(previewChars: { 0 }, capturing: drafts)
    watcher.pollOnce()

    try writeArchive(
      name: "2026-04-30T120000Z-102",
      handle: "+15550001000",
      text: "secret synthetic content that must not reach the lock screen"
    )
    watcher.pollOnce()

    XCTAssertEqual(drafts.count, 1)
    let draft = try XCTUnwrap(drafts.firstObject as? RecoveryNotificationDraft)
    XCTAssertEqual(draft.body, "", "preview 0 means NO recovered text in the banner")
    XCTAssertTrue(draft.recovered, "the notification itself still fires")
    XCTAssertTrue(draft.title.contains("+15550001000"))
  }

  func testPreviewSettingIsReadPerPollNotCachedAtStart() throws {
    let drafts = NSMutableArray()
    var limit = 200
    let watcher = makeWatcher(previewChars: { limit }, capturing: drafts)
    watcher.pollOnce()

    try writeArchive(name: "2026-04-30T120000Z-103", handle: "+15550001000", text: "abcdef")
    limit = 3  // user saved a tighter setting after the watcher started
    watcher.pollOnce()

    let draft = try XCTUnwrap(drafts.firstObject as? RecoveryNotificationDraft)
    XCTAssertEqual(draft.body, "abc")
  }
}
