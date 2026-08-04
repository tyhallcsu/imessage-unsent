import Foundation
import SQLite3

/// Resolves a handle (E.164 or Apple ID email) to a display name by reading the
/// local AddressBook stores directly, read-only.
///
/// Issue #179. The GUI's `CNContactStore` path cannot work on the shipped
/// artifact: it is ad-hoc signed, TCC has no stable identity to attach a grant
/// to, so `requestAccess` fails closed without prompting and the app never even
/// appears in Privacy → Contacts. There is no manual workaround there — that
/// pane lists only apps that successfully requested.
///
/// The daemon can do it because it holds **Full Disk Access**, which the user
/// grants by adding the binary in System Settings — a user-set grant that works
/// for an ad-hoc identity, and which supersedes the Contacts check for direct
/// reads of `~/Library/Application Support/AddressBook`. So resolution moves to
/// the daemon and names travel to the GUI over the existing control socket,
/// which is already how recovered text reaches it.
///
/// **Names are never logged.** `DaemonLog` scrubs phone numbers and emails, but a
/// personal name is not pattern-matchable — it would sail straight through the
/// redaction added in #174. Keep names out of log lines.
public final class AddressBookDirectory {
  private let sourcesDir: URL
  private let queue = DispatchQueue(label: "com.imu.watcher.addressbook")
  private var index: [String: String]?
  private var loadedAt: Date?

  /// Re-read no more often than this; the address book changes rarely and each
  /// refresh opens every source database.
  private let refreshInterval: TimeInterval

  public init(
    sourcesDir: URL = AddressBookDirectory.defaultSourcesDir(),
    refreshInterval: TimeInterval = 300
  ) {
    self.sourcesDir = sourcesDir
    self.refreshInterval = refreshInterval
  }

  public static func defaultSourcesDir(home: URL = imuUserHomeDirectory()) -> URL {
    home.appendingPathComponent("Library/Application Support/AddressBook/Sources", isDirectory: true)
  }

  /// The display name for a handle, or `nil` if unknown or unreadable.
  public func displayName(forHandle handle: String) -> ContactName? {
    guard let key = Self.indexKey(for: handle) else { return nil }
    return queue.sync {
      refreshIfNeeded()
      return index?[key].map(ContactName.init)
    }
  }

  /// Number of resolvable entries, for diagnostics. Never exposes the entries.
  public func entryCount() -> Int {
    queue.sync {
      refreshIfNeeded()
      return index?.count ?? 0
    }
  }

  private func refreshIfNeeded() {
    if let loadedAt, Date().timeIntervalSince(loadedAt) < refreshInterval, index != nil {
      return
    }
    index = Self.buildIndex(sourcesDir: sourcesDir)
    loadedAt = Date()
  }

  // MARK: - Matching

  /// Phone numbers are stored formatted ("(720) 555-0123") in the address book and
  /// E.164 ("+17205550123") in chat.db, so match on the last 10 digits — enough to
  /// be unambiguous in practice, and tolerant of country-code and formatting
  /// differences. Emails match case-insensitively on the whole string.
  static func indexKey(for raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("@") {
      return "e:" + trimmed.lowercased()
    }
    let digits = trimmed.filter(\.isNumber)
    guard digits.count >= 7 else { return nil }
    return "p:" + String(digits.suffix(10))
  }

  static func displayName(first: String?, last: String?, organization: String?) -> String? {
    let parts = [first, last].compactMap { $0 }.filter { !$0.isEmpty }
    if !parts.isEmpty { return parts.joined(separator: " ") }
    if let organization, !organization.isEmpty { return organization }
    return nil
  }

  // MARK: - Reading

  private static func buildIndex(sourcesDir: URL) -> [String: String] {
    var index: [String: String] = [:]
    let fm = FileManager.default
    guard let sources = try? fm.contentsOfDirectory(
      at: sourcesDir, includingPropertiesForKeys: nil
    ) else {
      // No FDA, or no address book. Not an error — the feature degrades to
      // showing raw handles, which is what happened before this existed.
      return index
    }

    for source in sources {
      let db = source.appendingPathComponent("AddressBook-v22.abcddb", isDirectory: false)
      guard fm.fileExists(atPath: db.path) else { continue }
      merge(from: db, into: &index)
    }
    return index
  }

  private static func merge(from db: URL, into index: inout [String: String]) {
    var handle: OpaquePointer?
    let uri = "file://\(db.path)?mode=ro"
    guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
          let handle else {
      sqlite3_close(handle)
      return
    }
    defer { sqlite3_close(handle) }

    let phoneSQL = """
    SELECT p.ZFULLNUMBER, r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION
    FROM ZABCDPHONENUMBER p JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER
    WHERE p.ZFULLNUMBER IS NOT NULL;
    """
    let emailSQL = """
    SELECT e.ZADDRESS, r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION
    FROM ZABCDEMAILADDRESS e JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER
    WHERE e.ZADDRESS IS NOT NULL;
    """

    for sql in [phoneSQL, emailSQL] {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        // A source may predate a column (older schema); skip it rather than
        // failing the whole lookup.
        sqlite3_finalize(stmt)
        continue
      }
      defer { sqlite3_finalize(stmt) }

      while sqlite3_step(stmt) == SQLITE_ROW {
        guard let raw = column(stmt, 0) else { continue }
        guard let key = indexKey(for: raw) else { continue }
        guard let name = displayName(
          first: column(stmt, 1), last: column(stmt, 2), organization: column(stmt, 3)
        ) else { continue }
        // First writer wins: sources are enumerated in a stable order, and a
        // later duplicate should not silently replace an earlier name.
        if index[key] == nil { index[key] = name }
      }
    }
  }

  private static func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard let text = sqlite3_column_text(stmt, index) else { return nil }
    let value = String(cString: text)
    return value.isEmpty ? nil : value
  }
}
