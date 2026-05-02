import XCTest
@testable import IMUCore

final class RestoreModeGuardTests: XCTestCase {
  func testDefaultConfigIsNotifyOnly() {
    let config = DaemonConfig()
    XCTAssertFalse(RestoreModeGuard.isRestoreModeEnabled(config))
  }

  func testRequireRestoreModeThrowsWhenDisabled() {
    let config = DaemonConfig(experimental: ExperimentalConfig(restoreMode: false))
    XCTAssertThrowsError(try RestoreModeGuard.requireRestoreMode(config: config)) { error in
      XCTAssertEqual(error as? RestoreModeGuardError, .notifyOnlyMode)
    }
  }

  func testRequireRestoreModeReturnsNormallyWhenEnabled() throws {
    let config = DaemonConfig(experimental: ExperimentalConfig(restoreMode: true))
    XCTAssertNoThrow(try RestoreModeGuard.requireRestoreMode(config: config))
  }

  func testIsRestoreModeEnabledReflectsConfig() {
    XCTAssertFalse(
      RestoreModeGuard.isRestoreModeEnabled(
        DaemonConfig(experimental: ExperimentalConfig(restoreMode: false))
      )
    )
    XCTAssertTrue(
      RestoreModeGuard.isRestoreModeEnabled(
        DaemonConfig(experimental: ExperimentalConfig(restoreMode: true))
      )
    )
  }

  func testNotifyOnlyErrorMessageMentionsTheInvariant() {
    let error = RestoreModeGuardError.notifyOnlyMode
    let description = error.errorDescription ?? ""
    XCTAssertTrue(
      description.contains("Notify-only") || description.contains("restore_mode"),
      "error description must explain why the write was refused: got '\(description)'"
    )
  }
}
