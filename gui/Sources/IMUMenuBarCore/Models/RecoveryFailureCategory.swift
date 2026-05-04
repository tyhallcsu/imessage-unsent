import Foundation

// Mirror of daemon/Sources/IMUCore/RecoveryFailureCategory.swift. The two
// packages don't share a target, so when adding/renaming a case keep both
// files in lockstep — RecoveryFailureCategoryTests on each side covers the
// raw-value contract.

public enum RecoveryFailureCategory: String, Codable, Equatable, CaseIterable {
  case walCheckpointed = "wal_checkpointed"
  case unknownHandle = "unknown_handle"
  case notInLocalWAL = "not_in_local_wal"
  case attachmentOnly = "attachment_only"
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
    case .scriptError:
      return "The recovery script failed before producing output."
    case .unknown:
      return "Recovery did not find text. Cause not determined."
    }
  }

  public var actionableHint: String? {
    switch self {
    case .walCheckpointed:
      return "Keep the daemon running before unsends — rolling WAL history (#67) helps for long messages."
    case .unknownHandle:
      return "This sometimes resolves itself as Messages syncs handles. Check the archive again in a few minutes."
    case .notInLocalWAL:
      return "Common for group-chat retractions where the remote retract didn't propagate. Nothing recoverable on this device."
    case .attachmentOnly:
      return "Attachment recovery is tracked separately — see the Limitations section in README."
    case .scriptError:
      return "Please file a bug with the contents of recovery.stderr.txt from the archive directory."
    case .unknown:
      return nil
    }
  }
}
