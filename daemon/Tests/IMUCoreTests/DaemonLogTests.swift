import XCTest
@testable import IMUCore

/// Issue #174. Measured on a real install before this landed: 242 `handle=+1…`
/// lines in `watcher.log`, 1.3 MB, one file — rotation had never run.
final class DaemonLogTests: XCTestCase {
  private var dir: URL!
  private var logURL: URL!
  private var saltURL: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-log-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    logURL = dir.appendingPathComponent("watcher.log", isDirectory: false)
    saltURL = dir.appendingPathComponent("log-salt", isDirectory: false)
  }

  override func tearDown() {
    if let dir { try? FileManager.default.removeItem(at: dir) }
    dir = nil
  }

  private func contents() -> String {
    (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
  }

  // MARK: - Redaction

  func testTheRealLogLineNoLongerLeaksTheHandle() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL)
    // Verbatim shape of the line that produced 242 leaks.
    log.write("retraction detected rowid=412149 guid=ABC-123 handle=+15551234567 edited_at=806")

    let written = contents()
    XCTAssertFalse(written.contains("+15551234567"), "the E.164 must not reach the file")
    XCTAssertTrue(written.contains("h:"), "it should be replaced by a fingerprint")
    // Everything needed to correlate with the archive survives.
    XCTAssertTrue(written.contains("rowid=412149"))
    XCTAssertTrue(written.contains("guid=ABC-123"))
  }

  func testAppleIDEmailsAreRedactedToo() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL)
    log.write("handle=someone@example.com detected")
    XCTAssertFalse(contents().contains("someone@example.com"))
    XCTAssertTrue(contents().contains("h:"))
  }

  func testAnyFutureLogStatementIsCoveredToo() {
    // The scrubber runs on every line rather than at call sites, so a statement
    // nobody thought about cannot leak. This is the allowlist lesson from #25.
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL)
    log.write("some brand new message about +14155550123 that nobody redacted by hand")
    XCTAssertFalse(contents().contains("+14155550123"))
  }

  func testMultipleIdentifiersOnOneLineAreAllRedacted() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL)
    log.write("from=+15551234567 to=+15559998888 cc=a@b.com")
    let written = contents()
    for leak in ["+15551234567", "+15559998888", "a@b.com"] {
      XCTAssertFalse(written.contains(leak), "\(leak) leaked")
    }
    XCTAssertEqual(written.components(separatedBy: "h:").count - 1, 3)
  }

  func testFingerprintIsStableSoLinesStayCorrelatable() {
    let salt = Data(repeating: 0xAB, count: 32)
    let a = DaemonLog.fingerprint("+15551234567", salt: salt)
    let b = DaemonLog.fingerprint("+15551234567", salt: salt)
    let other = DaemonLog.fingerprint("+15559998888", salt: salt)
    XCTAssertEqual(a, b, "the same handle must fingerprint identically across lines")
    XCTAssertNotEqual(a, other)
    XCTAssertTrue(a.hasPrefix("h:"))
  }

  func testDifferentSaltsProduceDifferentFingerprints() {
    // An unsalted hash of a phone number is a ~10^10 search space — seconds to
    // reverse. Without this property the redaction would be decorative.
    let a = DaemonLog.fingerprint("+15551234567", salt: Data(repeating: 0x01, count: 32))
    let b = DaemonLog.fingerprint("+15551234567", salt: Data(repeating: 0x02, count: 32))
    XCTAssertNotEqual(a, b)
  }

  func testSaltIsPersistedOwnerOnlyAndReused() throws {
    let first = DaemonLog(fileURL: logURL, saltURL: saltURL)
    first.write("handle=+15551234567")
    let firstLine = contents()

    let mode = try FileManager.default.attributesOfItem(atPath: saltURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600, "the salt must not be world-readable")

    // A second instance (i.e. a daemon restart) reuses it, so history stays joinable.
    try? FileManager.default.removeItem(at: logURL)
    let second = DaemonLog(fileURL: logURL, saltURL: saltURL)
    second.write("handle=+15551234567")
    let firstHash = firstLine.components(separatedBy: "h:")[1].prefix(12)
    XCTAssertTrue(contents().contains("h:" + firstHash))
  }

  func testRedactionCanBeDisabledForDebugging() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL, redact: false)
    log.write("handle=+15551234567")
    XCTAssertTrue(contents().contains("+15551234567"))
  }

  // MARK: - Rotation

  func testRotatesOnceOverTheCapAndKeepsOneGeneration() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL, maxBytes: 2_048)
    for i in 0..<200 {
      log.write("line \(i) " + String(repeating: "x", count: 100))
    }

    let rotated = logURL.appendingPathExtension("1")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: rotated.path),
      "a generation should exist once the cap is passed"
    )
    let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
    XCTAssertLessThanOrEqual(
      size ?? 0, 2_048 + 4_096,
      "the live log must stay near the cap rather than growing to 1.3 MB"
    )
    // Exactly one generation — not an unbounded pile of .1 .2 .3
    let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    XCTAssertEqual(siblings.filter { $0.hasPrefix("watcher.log") }.count, 2)
  }

  func testDoesNotRotateBelowTheCap() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL, maxBytes: 1_000_000)
    log.write("short")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path)
    )
  }

  func testLogFileIsOwnerOnly() throws {
    DaemonLog(fileURL: logURL, saltURL: saltURL).write("hello")
    let mode = try FileManager.default.attributesOfItem(atPath: logURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600, "the log holds correspondence metadata")
  }

  func testWritesAreAppendedNotOverwritten() {
    let log = DaemonLog(fileURL: logURL, saltURL: saltURL)
    log.write("first")
    log.write("second")
    XCTAssertTrue(contents().contains("first"))
    XCTAssertTrue(contents().contains("second"))
  }
}
