import Foundation

/// Errors thrown when a write-mode-only code path runs without the user
/// having explicitly opted in to ``ExperimentalConfig/restoreMode``.
public enum RestoreModeGuardError: Error, LocalizedError, Equatable {
  /// The current daemon config has `experimental.restore_mode = false`.
  /// Any code path that mutates the user's live `chat.db` MUST refuse to run.
  case notifyOnlyMode

  /// The caller asked to write to a path outside the live Messages directory.
  /// Currently always rejected; reserved for the future Restore-mode flow.
  case unsupportedTarget(String)

  public var errorDescription: String? {
    switch self {
    case .notifyOnlyMode:
      return "experimental.restore_mode is false: refusing to write to chat.db (Notify-only mode)"
    case let .unsupportedTarget(path):
      return "refusing to write to unsupported target: \(path)"
    }
  }
}

/// Gatekeeper for any future code path that wants to mutate the user's live
/// `chat.db` (issue #16, experimental "Restore" mode).
///
/// Issue #17 codifies the **Notify-only** invariant: the v0.2 daemon observes
/// retractions and archives recovered text, but **never** writes back to the
/// live database. This guard makes that invariant explicit and testable.
///
/// Usage (when issue #16 lands):
///
/// ```swift
/// try RestoreModeGuard.requireRestoreMode(config: daemonConfig)
/// // ... write-back code only past this line ...
/// ```
///
/// Today no daemon code calls into the guard, because no daemon code writes
/// to `chat.db`. The structural test in `RestoreModeGuardTests` asserts the
/// guard's behavior so a future PR adding a write path cannot bypass it
/// without reviewers noticing.
///
/// > Important: Flipping `experimental.restore_mode` to `true` in config is
/// > **not sufficient** by itself. The future Restore flow (issue #16) must
/// > also walk the user through an explicit consent dialog that names the
/// > exact rows being mutated and creates a recovery snapshot of `chat.db`
/// > before any UPDATE. The consent flow is out of scope for issue #17.
public enum RestoreModeGuard {
  /// Throws ``RestoreModeGuardError/notifyOnlyMode`` if the daemon is in the
  /// default Notify-only mode. Returns normally only when the user has
  /// explicitly opted in via `experimental.restore_mode = true`.
  ///
  /// Callers should additionally verify that the per-invocation consent
  /// flow has been completed (see issue #16). This guard checks the static
  /// config flag only.
  public static func requireRestoreMode(config: DaemonConfig) throws {
    guard config.experimental.restoreMode else {
      throw RestoreModeGuardError.notifyOnlyMode
    }
  }

  /// Returns `true` if and only if the daemon is permitted to attempt
  /// write-back to `chat.db`. Never `true` by default.
  public static func isRestoreModeEnabled(_ config: DaemonConfig) -> Bool {
    config.experimental.restoreMode
  }
}
