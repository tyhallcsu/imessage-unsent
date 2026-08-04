import Foundation

/// The one predicate for "did this archive actually recover readable text?".
///
/// Issue #172. Three places asked that question and two answered it wrongly:
///
/// - `ArchivePipeline.recoveryJSONHasText` checked only that `text_b64` was a
///   non-empty *string*, and that value sets `recovered` on the manifest — so an
///   archive holding undecodable garbage was reported as a successful recovery,
///   with a success notification and the retry button hidden.
/// - `ArchiveCompactor` checked only that `recovery.json` was readable and
///   non-empty before irreversibly deleting the chat.db family and wal-history —
///   the only remaining sources once the live WAL has checkpointed — despite a
///   doc comment claiming it refused on unparseable input.
/// - `ArchiveHistoryReader` did it correctly, which is why the History list could
///   disagree with the manifest about the same archive.
///
/// "Recovered" means: the JSON parses, `recovered.text_b64` is present, it is
/// valid Base64, those bytes are valid UTF-8, and the result is non-empty. A
/// value that fails any step is not text we can show a user, so it must not be
/// counted as a recovery and must not authorise deleting the evidence.
public enum RecoveredText {
  /// The decoded message, or `nil` if this payload does not contain readable text.
  public static func decode(fromRecoveryJSON data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let payload = object as? [String: Any],
      let recovered = payload["recovered"] as? [String: Any],
      let textB64 = recovered["text_b64"] as? String,
      !textB64.isEmpty,
      let raw = Data(base64Encoded: textB64),
      let text = String(data: raw, encoding: .utf8),
      !text.isEmpty
    else {
      return nil
    }
    return text
  }

  /// Convenience for callers that only need the yes/no.
  public static func isPresent(inRecoveryJSON data: Data) -> Bool {
    decode(fromRecoveryJSON: data) != nil
  }
}
