import XCTest
@testable import IMUMenuBarCore

final class SettingsDocumentTests: XCTestCase {
  func testSettingsUpdatePreservesUnknownLinesAndDisablesRestore() {
    let raw = """
    custom_key = "keep-me"

    [notifications]
    show = true
    preview_chars = 80

    [unknown]
    value = 42

    [experimental]
    restore_mode = true
    """
    var settings = SettingsDocument(rawText: raw).parse()
    settings.previewChars = 0
    settings.retentionLimit = 10

    let updated = SettingsDocument(rawText: raw).updating(settings)
    XCTAssertTrue(updated.contains("custom_key = \"keep-me\""))
    XCTAssertTrue(updated.contains("[unknown]"))
    XCTAssertTrue(updated.contains("preview_chars = 0"))
    XCTAssertTrue(updated.contains("keep_last = 10"))
    XCTAssertTrue(updated.contains("restore_mode = false"))
    XCTAssertFalse(updated.contains("restore_mode = true"))
  }
}
