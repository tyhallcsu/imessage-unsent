import Foundation

/// A resolved contact name that cannot be logged by accident.
///
/// `DaemonLog` redacts phone numbers and Apple ID emails by regex (#174), which
/// works because both have a shape. A personal name has no shape — you cannot
/// pattern-match "Ada Lovelace" out of arbitrary text. The obvious alternative,
/// scrubbing against a denylist built from the address book, is worse than
/// useless: on the machine this was developed against that denylist would hold
/// ~2,100 entries including organisation names, so a contact called "Apple" or
/// "Test" would silently redact those words out of unrelated log lines and make
/// the log untrustworthy in the other direction.
///
/// So this is enforced by the type instead of by a scrubber. The accidental path
/// — string interpolation, `print`, `String(describing:)` — yields
/// `<name redacted>`. Getting the real value requires calling `unredacted()`,
/// which is explicit, greppable, and currently has exactly one caller: the
/// control-socket serializer that sends the name to the GUI.
///
/// This is a narrower guarantee than the regex scrubber, and deliberately so: it
/// protects against forgetting, not against someone who means it. Someone can
/// still write `log(name.unredacted())`. But that is now a visible, reviewable
/// act rather than an ordinary-looking interpolation.
public struct ContactName: Equatable, Hashable, CustomStringConvertible,
                           CustomDebugStringConvertible {
  private let value: String

  public init(_ value: String) {
    self.value = value
  }

  /// What `"\(name)"` produces. Never the name.
  public var description: String { "<name redacted>" }

  /// What `debugPrint` and `"\(name, default:)"`-style paths produce.
  public var debugDescription: String { "<name redacted>" }

  /// The real value. The only way out, and intentionally awkward enough to
  /// notice in review.
  public func unredacted() -> String { value }

  public var isEmpty: Bool { value.isEmpty }
}
