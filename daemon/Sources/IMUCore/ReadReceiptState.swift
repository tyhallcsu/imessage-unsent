import Foundation

/// Receipt state for one `message` row, mirroring Vector 8's model.
///
/// `chat.db` stores the flag (`is_read`) and the timestamp (`date_read`)
/// independently, and they disagree constantly — which is three states, not
/// the boolean Messages.app renders. See `docs/recovery-vectors.md` § Vector 8
/// and `scripts/read-receipts.py`, which this deliberately matches so the CLI
/// and the daemon never describe the same row differently.
public enum ReadReceiptState: String, Codable, Equatable, Sendable {
  /// `date_* != 0` — the exact receipt time is on this Mac.
  case timestamped
  /// `is_* = 1, date_* = 0` — it happened; the time was never written here.
  case flaggedOnly = "flagged_only"
  /// `is_* = 0, date_* = 0` — no receipt at all.
  case none

  /// A timestamp always wins the flag: if we have the time, we know it happened.
  public static func classify(flag: Bool, timestamp: Int64) -> ReadReceiptState {
    if normalizeAppleTimestamp(timestamp) != 0 {
      return .timestamped
    }
    return flag ? .flaggedOnly : .none
  }
}

/// Apple-epoch *seconds* top out around 1.5e9, so anything at or above this is
/// nanosecond-precision. Modern chat.db rows are entirely ns; second-precision
/// rows survive in migrated-forward databases. Kept in sync with
/// `scripts/lib/chatdb_time.py`.
private let nsPrecisionFloor: Int64 = 100_000_000_000

/// Raw `message` timestamp → Apple-epoch nanoseconds. 0 stays 0 ("unset").
public func normalizeAppleTimestamp(_ value: Int64) -> Int64 {
  guard value != 0 else { return 0 }
  if abs(value) < nsPrecisionFloor {
    return value * 1_000_000_000
  }
  return value
}

/// What the receipt columns on a retracted row say about whether the local user
/// saw the message before the sender pulled it back.
///
/// The detector only watches inbound rows (`is_from_me = 0`), so this is always
/// *you* reading *their* message. It makes no claim about what the sender saw.
public struct RetractionReadContext: Codable, Equatable, Sendable {
  public let readState: ReadReceiptState
  public let dateRead: Int64
  public let deliveredState: ReadReceiptState
  public let dateDelivered: Int64

  /// `true` when the read receipt predates the retraction — you saw the
  /// original. `false` when it does not: the read timestamp landed at or after
  /// `date_edited`, meaning Messages marked the *tombstone* read, not the
  /// message. `nil` when `readState` is not `.timestamped`, because without a
  /// time the two events cannot be ordered at all.
  public let readBeforeRetraction: Bool?

  /// Signed seconds from the read receipt to the retraction: positive means you
  /// read it that long *before* it was unsent. `nil` unless `readState` is
  /// `.timestamped`.
  public let readToRetractSeconds: Double?

  public init(isRead: Bool, dateRead: Int64, isDelivered: Bool, dateDelivered: Int64, editedAt: Int64) {
    let normalizedRead = normalizeAppleTimestamp(dateRead)
    let normalizedEdited = normalizeAppleTimestamp(editedAt)

    self.readState = ReadReceiptState.classify(flag: isRead, timestamp: dateRead)
    self.dateRead = dateRead
    self.deliveredState = ReadReceiptState.classify(flag: isDelivered, timestamp: dateDelivered)
    self.dateDelivered = dateDelivered

    if self.readState == .timestamped, normalizedEdited != 0 {
      let delta = Double(normalizedEdited - normalizedRead) / 1_000_000_000
      // An exactly-equal timestamp is not evidence you saw it first, so `>`
      // rather than `>=`.
      self.readBeforeRetraction = normalizedRead < normalizedEdited
      self.readToRetractSeconds = delta
    } else {
      self.readBeforeRetraction = nil
      self.readToRetractSeconds = nil
    }
  }

  enum CodingKeys: String, CodingKey {
    case readState = "read_state"
    case dateRead = "date_read"
    case deliveredState = "delivered_state"
    case dateDelivered = "date_delivered"
    case readBeforeRetraction = "read_before_retraction"
    case readToRetractSeconds = "read_to_retract_seconds"
  }
}

/// Seconds between the UNIX epoch and Apple's 2001-01-01 epoch.
private let appleEpochOffset: TimeInterval = 978_307_200

/// `Date` → Apple-epoch nanoseconds, the unit every `message` timestamp column uses.
public func appleEpochNanoseconds(from date: Date) -> Int64 {
  Int64((date.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)
}
