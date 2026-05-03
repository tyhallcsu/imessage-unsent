import Foundation

@MainActor
public final class SettingsModel: ObservableObject {
  @Published public var draft: SettingsConfig
  @Published public private(set) var savedConfig: SettingsConfig
  @Published public private(set) var lastSaveError: String?
  @Published public private(set) var didSaveAt: Date?

  public let store: ConfigFileStoring

  public init(store: ConfigFileStoring = ConfigFileStore()) {
    self.store = store
    let loaded = store.load()
    self.draft = loaded
    self.savedConfig = loaded
  }

  public var isDirty: Bool {
    draft != savedConfig
  }

  public var configURL: URL {
    store.configURL
  }

  /// Reloads from disk, discarding any unsaved edits.
  public func reload() {
    let loaded = store.load()
    draft = loaded
    savedConfig = loaded
    lastSaveError = nil
  }

  /// Persists `draft` to disk. Returns true on success, false otherwise (and
  /// surfaces the error via `lastSaveError`).
  @discardableResult
  public func save() -> Bool {
    do {
      try store.save(draft)
      savedConfig = draft
      didSaveAt = Date()
      lastSaveError = nil
      return true
    } catch {
      lastSaveError = error.localizedDescription
      return false
    }
  }

  /// Discards in-memory edits and reverts `draft` to the last saved state.
  public func revertEdits() {
    draft = savedConfig
    lastSaveError = nil
  }
}
