import Foundation
import XCTest
@testable import IMUMenuBarCore

@MainActor
final class SettingsModelTests: XCTestCase {
  func testInitialDraftMatchesStoredConfig() {
    let store = StubStore(initial: SettingsConfig(archiveRetention: 250))
    let model = SettingsModel(store: store)

    XCTAssertEqual(model.draft.archiveRetention, 250)
    XCTAssertEqual(model.savedConfig.archiveRetention, 250)
    XCTAssertFalse(model.isDirty)
  }

  func testEditingDraftMakesItDirty() {
    let model = SettingsModel(store: StubStore(initial: SettingsConfig()))
    model.draft.notifications.show = false

    XCTAssertTrue(model.isDirty)
  }

  func testSavePersistsAndClearsDirty() {
    let store = StubStore(initial: SettingsConfig())
    let model = SettingsModel(store: store)
    model.draft.notifications.previewChars = 50

    XCTAssertTrue(model.save())

    XCTAssertFalse(model.isDirty)
    XCTAssertEqual(store.savedHistory.last?.notifications.previewChars, 50)
    XCTAssertNotNil(model.didSaveAt)
    XCTAssertNil(model.lastSaveError)
  }

  func testSaveSurfacesError() {
    let store = StubStore(initial: SettingsConfig())
    store.shouldFail = true
    let model = SettingsModel(store: store)
    model.draft.notifications.show = false

    XCTAssertFalse(model.save())

    XCTAssertTrue(model.isDirty, "draft is unchanged on failure so the user can retry")
    XCTAssertEqual(model.lastSaveError, "stub failure")
  }

  func testRevertEditsRestoresSavedState() {
    let model = SettingsModel(store: StubStore(initial: SettingsConfig(archiveRetention: 100)))
    model.draft.archiveRetention = 1000

    model.revertEdits()

    XCTAssertEqual(model.draft.archiveRetention, 100)
    XCTAssertFalse(model.isDirty)
  }

  func testReloadDiscardsUnsavedEdits() {
    let store = StubStore(initial: SettingsConfig(archiveRetention: 50))
    let model = SettingsModel(store: store)
    model.draft.archiveRetention = 999
    XCTAssertTrue(model.isDirty)

    store.initial = SettingsConfig(archiveRetention: 75)
    model.reload()

    XCTAssertEqual(model.draft.archiveRetention, 75)
    XCTAssertEqual(model.savedConfig.archiveRetention, 75)
    XCTAssertFalse(model.isDirty)
  }
}

private final class StubStore: ConfigFileStoring {
  var initial: SettingsConfig
  var shouldFail = false
  private(set) var savedHistory: [SettingsConfig] = []
  let configURL = URL(fileURLWithPath: "/tmp/stub-imu/config.toml")

  init(initial: SettingsConfig) {
    self.initial = initial
  }

  func load() -> SettingsConfig {
    initial
  }

  func save(_ config: SettingsConfig) throws {
    if shouldFail {
      throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "stub failure"])
    }
    savedHistory.append(config)
    initial = config
  }
}
