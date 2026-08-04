import Foundation

public enum RecoveryFailureCategory: String, Codable, Equatable, CaseIterable {
  case walCheckpointed = "wal_checkpointed"
  case unknownHandle = "unknown_handle"
  case notInLocalWAL = "not_in_local_wal"
  case attachmentOnly = "attachment_only"
  /// The retraction happened before this fresh-state launch started monitoring —
  /// a launch that begins from missing or quarantined state (a corrupt state file
  /// is quarantined at startup, so the daemon may well have been running for
  /// months before; whether it was is unknown here).
  ///
  /// Note this is measured against the launch instant, not against the seeded
  /// high-water mark: the seed sits a grace window EARLIER, so an event can be
  /// after the seed (hence detected at all) and still before monitoring started. A miss in this
  /// category reflects when this launch began monitoring, not the health of the daemon,
  /// and is not proof the text was unrecoverable — an older page can still be in
  /// the live WAL. Distinct from `walCheckpointed`, which means we
  /// could not be inferred: without a fresh-state launch we cannot tell whether we
  /// were tracking at the time, so `walCheckpointed` is the honest default (#160).
  case predatesMonitoring = "predates_monitoring"
  case scriptError = "script_error"
  case unknown

  public var displayMessage: String {
    switch self {
    case .walCheckpointed:
      return "WAL was already checkpointed before the daemon caught the unsend."
    case .unknownHandle:
      return "The sender's handle wasn't in the contacts table at recovery time."
    case .notInLocalWAL:
      return "This unsend never reached your device's local WAL."
    case .attachmentOnly:
      return "The original message was attachment-only — no text body to recover."
    case .predatesMonitoring:
      return "This unsend happened before the daemon last started monitoring from a fresh state."
    case .scriptError:
      return "The recovery script failed before producing output."
    case .unknown:
      return "Recovery did not find text. Cause not determined."
    }
  }

  public var actionableHint: String? {
    switch self {
    case .walCheckpointed:
      return "Keep the daemon running before unsends — rolling WAL history (#67) is scanned automatically and helps most for long messages."
    case .unknownHandle:
      return "This sometimes resolves itself as Messages syncs handles. Check the archive again in a few minutes."
    case .notInLocalWAL:
      return "Common for group-chat retractions where the remote retract didn't propagate. Nothing recoverable on this device."
    case .attachmentOnly:
      return "Attachment recovery is tracked separately — see the Limitations section in README."
    case .predatesMonitoring:
      return "Not a defect. Recovery is expected from the point monitoring begins; events preceding a fresh-state launch land here."
    case .scriptError:
      return "Please file a bug with the contents of recovery.stderr.txt from the archive directory."
    case .unknown:
      return nil
    }
  }
}
