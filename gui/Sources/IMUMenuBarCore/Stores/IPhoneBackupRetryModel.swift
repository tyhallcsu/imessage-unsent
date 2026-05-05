import Foundation
import SwiftUI

@MainActor
public final class IPhoneBackupRetryModel: ObservableObject {
  public enum State: Equatable {
    case idle
    case searching
    case found
    case noMatch
    case failed(reason: String)
  }

  @Published public private(set) var state: State = .idle

  private let runner: IPhoneBackupRetryRunning

  public init(runner: IPhoneBackupRetryRunning) {
    self.runner = runner
  }

  public var isRunning: Bool {
    if case .searching = state { return true }
    return false
  }

  public var statusMessage: String? {
    switch state {
    case .idle:
      return nil
    case .searching:
      return "Searching iPhone backup..."
    case .found:
      return "Found in iPhone backup"
    case .noMatch:
      return "No match in iPhone backup"
    case let .failed(reason):
      return "Error: \(reason)"
    }
  }

  public var statusSystemImage: String? {
    switch state {
    case .idle:
      return nil
    case .searching:
      return "magnifyingglass"
    case .found:
      return "checkmark.circle"
    case .noMatch:
      return "iphone.slash"
    case .failed:
      return "exclamationmark.triangle"
    }
  }

  public func retry(
    archiveDir: URL,
    handle: String,
    rowid: Int64
  ) async -> RecoveryDetail? {
    guard !isRunning else { return nil }

    state = .searching
    let result = await runner.run(
      archiveDir: archiveDir,
      handle: handle,
      rowid: rowid
    )
    switch result {
    case let .found(detail, _):
      state = .found
      return detail
    case let .noMatch(detail, _):
      state = .noMatch
      return detail
    case let .failure(message):
      state = .failed(reason: message)
      return nil
    }
  }
}
