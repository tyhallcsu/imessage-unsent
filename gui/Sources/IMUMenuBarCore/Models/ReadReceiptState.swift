import Foundation

/// Mirror of `IMUCore.ReadReceiptState`. The GUI and daemon are separate
/// SwiftPM packages with no shared target, so the enum is duplicated the same
/// way `RecoveryFailureCategory` is. Raw values must stay identical — they are
/// the manifest's on-disk contract.
public enum ReadReceiptState: String, Codable, Equatable, Sendable {
  case timestamped
  case flaggedOnly = "flagged_only"
  case none
}

/// Read-receipt context for a retracted message, as surfaced in the GUI.
///
/// The daemon only watches inbound retractions, so this always describes *you*
/// reading *their* message. It says nothing about what the sender saw.
public struct RecoveryReadReceipt: Equatable {
  public let readState: ReadReceiptState
  public let deliveredState: ReadReceiptState
  public let readBeforeRetraction: Bool?
  public let readToRetractSeconds: Double?

  public init(
    readState: ReadReceiptState,
    deliveredState: ReadReceiptState,
    readBeforeRetraction: Bool?,
    readToRetractSeconds: Double?
  ) {
    self.readState = readState
    self.deliveredState = deliveredState
    self.readBeforeRetraction = readBeforeRetraction
    self.readToRetractSeconds = readToRetractSeconds
  }

  /// One line for the detail view. Never claims more than the columns support:
  /// a flag without a timestamp cannot be ordered against the retraction, and
  /// says so rather than guessing.
  public var summary: String {
    switch readState {
    case .timestamped:
      guard let readBeforeRetraction else {
        return "Unknown — no retraction time to compare against"
      }
      if readBeforeRetraction {
        let gap = readToRetractSeconds.map(Self.formatDuration) ?? "some time"
        return "Yes — you read it \(gap) before it was unsent"
      }
      return "No — the read receipt landed after the retraction, so this was the placeholder, not the message"
    case .flaggedOnly:
      return "Marked read, but the time was never recorded on this Mac — can't tell whether that was before the retraction"
    case .none:
      return "No — the message was never marked read"
    }
  }

  /// Delivery is a separate fact from reading, and worth showing: a message can
  /// be retracted before it is ever delivered.
  public var deliverySummary: String {
    switch deliveredState {
    case .timestamped: return "Delivered"
    case .flaggedOnly: return "Delivered (time not recorded)"
    case .none: return "No delivery receipt"
    }
  }

  static func formatDuration(_ seconds: Double) -> String {
    let magnitude = abs(seconds)
    if magnitude < 60 {
      return String(format: "%.1fs", magnitude)
    }
    if magnitude < 3_600 {
      return String(format: "%.1f min", magnitude / 60)
    }
    if magnitude < 86_400 {
      return String(format: "%.1f h", magnitude / 3_600)
    }
    return String(format: "%.1f d", magnitude / 86_400)
  }
}
