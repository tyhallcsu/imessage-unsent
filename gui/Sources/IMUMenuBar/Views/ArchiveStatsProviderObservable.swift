import IMUMenuBarCore
import SwiftUI

/// Thin ObservableObject wrapper around the IMUMenuBarCore-side
/// `ArchiveStatsProvider`. The provider itself stays free of SwiftUI imports
/// so it can be unit-tested without the UI framework; this wrapper only
/// exists so SwiftUI views can use `@StateObject` to hold it.
@MainActor
final class ArchiveStatsProviderObservable: ObservableObject {
  let provider = ArchiveStatsProvider()

  func invalidateAll() {
    provider.invalidateAll()
    objectWillChange.send()
  }
}
