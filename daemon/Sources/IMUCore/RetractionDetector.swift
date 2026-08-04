import Foundation
import SQLite3

public struct RetractionDetected: Equatable {
  public let rowid: Int64
  public let guid: String
  public let handle: String
  public let editedAt: Int64

  /// Receipt state for this row, or `nil` when the database lacks the receipt
  /// columns. `nil` means "we don't know", never "it wasn't read".
  public let readContext: RetractionReadContext?

  /// True only when this launch seeded a FRESH baseline and the retraction predates
  /// it. After an ordinary restart with valid state, an older event is a genuine
  /// catch-up miss and keeps its real failure category.
  ///
  /// It says nothing about whether monitoring was active earlier — a quarantined
  /// corrupt state resets the baseline for an installation that had been running
  /// for months. Recovery is still attempted (the page may still be in the live
  /// WAL); a failure just means the miss is explained by where the baseline was
  /// set, not by losing a race we were running (issue #160).
  public let precedesMonitoring: Bool

  public init(
    rowid: Int64,
    guid: String,
    handle: String,
    editedAt: Int64,
    readContext: RetractionReadContext? = nil,
    precedesMonitoring: Bool = false
  ) {
    self.rowid = rowid
    self.guid = guid
    self.handle = handle
    self.editedAt = editedAt
    self.readContext = readContext
    self.precedesMonitoring = precedesMonitoring
  }
}

public struct DetectorState: Codable, Equatable {
  public var lastSeenDateEdited: Int64
  public var processedGUIDs: [String]
  public var attemptCounts: [String: Int]

  public init(
    lastSeenDateEdited: Int64 = 0,
    processedGUIDs: [String] = [],
    attemptCounts: [String: Int] = [:]
  ) {
    self.lastSeenDateEdited = lastSeenDateEdited
    self.processedGUIDs = processedGUIDs
    self.attemptCounts = attemptCounts
  }

  enum CodingKeys: String, CodingKey {
    case lastSeenDateEdited = "last_seen_date_edited"
    case processedGUIDs = "processed_guids"
    case attemptCounts = "attempt_counts"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.lastSeenDateEdited = try container.decode(Int64.self, forKey: .lastSeenDateEdited)
    self.processedGUIDs = try container.decodeIfPresent([String].self, forKey: .processedGUIDs) ?? []
    self.attemptCounts = try container.decodeIfPresent([String: Int].self, forKey: .attemptCounts) ?? [:]
  }
}

/// Where a loaded `DetectorState` came from. `missing` and `corrupt` both yield a
/// zeroed state, and a zeroed high-water mark means "every retraction ever recorded"
/// — so both must be seeded, not just the missing-file case (issue #160).
public enum DetectorStateOrigin: String, Equatable, Sendable {
  case existing
  case missing
  case corrupt
}

public struct LoadedDetectorState: Equatable {
  public let state: DetectorState
  public let origin: DetectorStateOrigin

  public var isFresh: Bool { origin != .existing }
}

public struct DetectorStateStore {
  public let url: URL
  private let logger: ((String) -> Void)?
  private let now: () -> Date

  public init(
    url: URL = defaultDetectorStateURL(),
    logger: ((String) -> Void)? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.url = url
    self.logger = logger
    self.now = now
  }

  /// Loads persisted detector state. A missing file yields a fresh state.
  ///
  /// A file that exists but cannot be decoded (truncated after a power loss,
  /// or corrupted during a crash-respawn cycle) is **quarantined** — renamed
  /// to `state.json.corrupt-<epoch>` — and a fresh state is returned rather
  /// than throwing. Throwing here would propagate out of `RetractionDetector.
  /// init` → the daemon's `run()` → `exit(1)`, and with `KeepAlive=true` in
  /// the LaunchAgent plist launchd would respawn straight back into the same
  /// failure ~every 10s, silently stopping all monitoring until a human
  /// deleted the file (issue #109). A one-time reset of the high-water mark is
  /// the acceptable cost; archive-dir naming keeps any re-archived events
  /// distinguishable.
  public func load() throws -> DetectorState {
    try loadWithOrigin().state
  }

  public func loadWithOrigin() throws -> LoadedDetectorState {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return LoadedDetectorState(state: DetectorState(), origin: .missing)
    }

    let data = try Data(contentsOf: url)
    do {
      return LoadedDetectorState(
        state: try JSONDecoder().decode(DetectorState.self, from: data),
        origin: .existing
      )
    } catch {
      quarantineCorruptState(decodeError: error)
      return LoadedDetectorState(state: DetectorState(), origin: .corrupt)
    }
  }

  private func quarantineCorruptState(decodeError: Error) {
    let stamp = Int(now().timeIntervalSince1970)
    let corruptURL = url.deletingLastPathComponent()
      .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)", isDirectory: false)
    // Best-effort move; if the rename fails we still return a fresh state so
    // the next save() overwrites the corrupt file atomically anyway.
    try? FileManager.default.removeItem(at: corruptURL)
    do {
      try FileManager.default.moveItem(at: url, to: corruptURL)
      logger?("detector state.json unreadable (\(decodeError.localizedDescription)); quarantined to \(corruptURL.lastPathComponent), starting from fresh state")
    } catch {
      logger?("detector state.json unreadable (\(decodeError.localizedDescription)); quarantine rename failed (\(error.localizedDescription)); starting from fresh state")
    }
  }

  public func save(_ state: DetectorState) throws {
    // state.json holds recovery metadata (processed message GUIDs + the
    // date_edited high-water mark). Keep it private: 0700 dir, 0600 file, to
    // match the 0700/0600 posture ArchivePipeline/WALSnapshotter already apply
    // to archives and snapshots (issue #128). The `.atomic` write replaces the
    // file via a fresh temp + rename, so the mode is reasserted after every
    // save rather than relying on the pre-existing file's mode.
    let parent = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

public enum RetractionDetectorError: Error, LocalizedError {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)
  case bindFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .openFailed(message):
      return "failed to open chat.db read-only: \(message)"
    case let .prepareFailed(message):
      return "failed to prepare detector query: \(message)"
    case let .stepFailed(message):
      return "failed to read detector query: \(message)"
    case let .bindFailed(message):
      return "failed to bind detector query: \(message)"
    }
  }
}

public final class RetractionDetector {
  /// How far back a fresh install looks. Zero would mean "every retraction ever
  /// recorded": on a real 412k-message database that produced 243 archives in 111
  /// seconds, each cloning a ~900 MB chat.db, and recovered exactly nothing —
  /// their WAL pages had been checkpointed away years earlier (issue #160).
  ///
  /// It is not zero either, because the realistic install sequence is "someone sees
  /// a message get unsent, THEN installs this" — starting at exactly now would skip
  /// the one event they installed for.
  ///
  /// Five minutes matches `WALSnapshotter`'s rolling-buffer window. That is a policy
  /// bound, NOT a proof of unrecoverability: the live WAL can still hold frames older
  /// than five minutes (it grows to ~4 MB before `wal_autocheckpoint` fires), so a
  /// longer window would occasionally succeed. We pick the buffer window because it
  /// is the span we control, and because the observed yield beyond it was 0 of 243.
  public static let defaultMonitoringGraceWindow: TimeInterval = 300

  public static let defaultMaxAttempts = 3
  public static let defaultMaxProcessedGUIDs = 5_000
  public static let defaultMaxAttemptCounts = 1_000

  private let chatDBURL: URL
  private let stateStore: DetectorStateStore
  private let maxAttempts: Int
  private let maxProcessedGUIDs: Int
  private let maxAttemptCounts: Int
  private var state: DetectorState

  /// Apple-epoch ns at which this process began watching. Retractions older than
  /// this fall outside the baseline established by THIS launch — which is not the
  /// same as never having been monitored, since a state reset re-establishes the
  /// baseline for an installation that was already running.
  public let monitoringStartedAt: Int64

  /// Whether this launch seeded a fresh baseline (no state, or corrupt state).
  public let didSeedFreshState: Bool

  public init(
    chatDBURL: URL = defaultMessagesChatDBURL(),
    stateStore: DetectorStateStore = DetectorStateStore(),
    maxAttempts: Int = RetractionDetector.defaultMaxAttempts,
    maxProcessedGUIDs: Int = RetractionDetector.defaultMaxProcessedGUIDs,
    maxAttemptCounts: Int = RetractionDetector.defaultMaxAttemptCounts,
    monitoringGraceWindow: TimeInterval = RetractionDetector.defaultMonitoringGraceWindow,
    now: () -> Date = Date.init
  ) throws {
    self.chatDBURL = chatDBURL
    self.stateStore = stateStore
    self.maxAttempts = maxAttempts
    self.maxProcessedGUIDs = maxProcessedGUIDs
    self.maxAttemptCounts = maxAttemptCounts

    let startedAt = now()
    self.monitoringStartedAt = appleEpochNanoseconds(from: startedAt)

    let loaded = try stateStore.loadWithOrigin()
    self.state = loaded.state
    self.didSeedFreshState = loaded.isFresh

    if loaded.isFresh {
      // A zeroed high-water mark means "every retraction ever". Seed it, and
      // persist BEFORE the first detect(): `markProcessed` returns early when
      // there are no events, so a quiet first launch would otherwise never write
      // state and every restart would re-baseline (issue #160).
      // Clamped at 0: a grace window larger than the age of the database seeds
      // to 0, which is the old "every retraction ever" behaviour. That makes the
      // knob continuous — a bigger number looks further back, with no sentinel.
      // Clamp before converting: `Int64(Double)` TRAPS on overflow, so an
      // arbitrarily large `monitoring_grace_seconds` typo would crash the daemon
      // on every launch — a launchd respawn loop, the #109 failure class. The
      // useful maximum is the age of the Apple epoch itself; beyond that the seed
      // is 0 ("all history") anyway.
      let maxUsefulGrace = max(0, startedAt.timeIntervalSince1970 - 978_307_200)
      let grace = min(max(0, monitoringGraceWindow), maxUsefulGrace)
      self.state.lastSeenDateEdited = max(0, appleEpochNanoseconds(
        from: startedAt.addingTimeInterval(-grace)
      ))
      try stateStore.save(self.state)
    }
  }

  public func detect() throws -> [RetractionDetected] {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
    guard sqlite3_open_v2(sqliteURI(for: chatDBURL), &database, flags, nil) == SQLITE_OK else {
      let message = database.map { sqliteMessage($0) } ?? "unknown sqlite error"
      sqlite3_close(database)
      throw RetractionDetectorError.openFailed(message)
    }
    guard let database else {
      throw RetractionDetectorError.openFailed("sqlite did not return a database handle")
    }
    defer {
      sqlite3_close(database)
    }

    // Receipt columns are additive metadata; detection is the daemon's job.
    // Probe rather than assume, so a schema variant that lacks them degrades
    // to "read state unknown" instead of failing every prepare and silently
    // ending retraction detection altogether.
    let hasReceiptColumns = messageTableHasReceiptColumns(database: database)

    let candidates = try queryRetractions(
      database: database,
      after: state.lastSeenDateEdited,
      includeReceiptColumns: hasReceiptColumns
    )
    let processed = Set(state.processedGUIDs)
    return candidates.filter { !processed.contains($0.guid) }
  }

  public func markProcessed(_ events: [RetractionDetected]) throws {
    guard let maxEditedAt = events.map(\.editedAt).max() else {
      return
    }

    // Never advance the high-water past a NON-terminal event — one that
    // still carries a live attempt count (markFailed below the ceiling).
    // The SQL filter is `date_edited > lastSeenDateEdited`, so advancing
    // past it would exclude the event from every future detect() and the
    // maxAttempts retry ceiling could never be reached (#142 / F-M4).
    // Terminal events (markRecovered, or markFailed at the ceiling) have no
    // attempt count and are deduped by processedGUIDs instead, so the mark
    // can move past them freely.
    let nonTerminalFloor = events
      .filter { state.attemptCounts[$0.guid] != nil }
      .map { $0.editedAt - 1 }
      .min()

    let newHighWater = nonTerminalFloor.map { min($0, maxEditedAt) } ?? maxEditedAt
    guard newHighWater > state.lastSeenDateEdited else {
      return
    }

    state.lastSeenDateEdited = newHighWater
    try stateStore.save(state)
  }

  public func markRecovered(guid: String) throws {
    var changed = false
    if !state.processedGUIDs.contains(guid) {
      state.processedGUIDs.append(guid)
      state.processedGUIDs.sort()
      changed = true
    }
    if state.attemptCounts.removeValue(forKey: guid) != nil {
      changed = true
    }
    if changed {
      pruneState()
      try stateStore.save(state)
    }
  }

  public func markFailed(guid: String) throws {
    let nextCount = (state.attemptCounts[guid] ?? 0) + 1
    if nextCount >= maxAttempts {
      if !state.processedGUIDs.contains(guid) {
        state.processedGUIDs.append(guid)
        state.processedGUIDs.sort()
      }
      state.attemptCounts.removeValue(forKey: guid)
    } else {
      state.attemptCounts[guid] = nextCount
    }
    pruneState()
    try stateStore.save(state)
  }

  public func currentState() -> DetectorState {
    state
  }

  // Bounded growth: drop the lexicographically smallest GUIDs once we exceed
  // the cap. processedGUIDs is kept sorted, so this is a deterministic,
  // stable-across-restarts O(1) drop. The high-water-mark
  // `lastSeenDateEdited` is the primary dedup; processedGUIDs is a backstop
  // for retractions that share the same date_edited boundary, so eviction
  // here can only reawaken retractions whose timestamp matches the boundary
  // exactly — extremely rare in practice and harmless if it happens.
  private func pruneState() {
    if state.processedGUIDs.count > maxProcessedGUIDs {
      let excess = state.processedGUIDs.count - maxProcessedGUIDs
      state.processedGUIDs.removeFirst(excess)
    }
    if state.attemptCounts.count > maxAttemptCounts {
      let excess = state.attemptCounts.count - maxAttemptCounts
      let dropKeys = state.attemptCounts.keys.sorted().prefix(excess)
      for key in dropKeys {
        state.attemptCounts.removeValue(forKey: key)
      }
    }
  }

  /// `PRAGMA table_info` over `message`, checked once per detect() pass.
  /// Returns false on any error — an unreadable pragma must not be fatal to
  /// detection, it just means we fall back to the columns we know exist.
  private func messageTableHasReceiptColumns(database: OpaquePointer) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(message);", -1, &statement, nil) == SQLITE_OK,
          let statement else {
      sqlite3_finalize(statement)
      return false
    }
    defer { sqlite3_finalize(statement) }

    var found: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      found.insert(sqliteText(statement, column: 1))
    }
    return Self.receiptColumns.isSubset(of: found)
  }

  private static let receiptColumns: Set<String> = [
    "is_read", "date_read", "is_delivered", "date_delivered"
  ]

  private func queryRetractions(
    database: OpaquePointer,
    after lastSeenDateEdited: Int64,
    includeReceiptColumns: Bool
  ) throws -> [RetractionDetected] {
    var events: [RetractionDetected] = []
    var upperDateEdited = Int64.max
    var upperRowID = Int64.max

    while true {
      let page = try queryRetractionPage(
        database: database,
        after: lastSeenDateEdited,
        beforeDateEdited: upperDateEdited,
        beforeRowID: upperRowID,
        includeReceiptColumns: includeReceiptColumns
      )
      events.append(contentsOf: page)

      guard page.count == 50, let last = page.last else {
        break
      }

      upperDateEdited = last.editedAt
      upperRowID = last.rowid
    }

    return events
  }

  private func queryRetractionPage(
    database: OpaquePointer,
    after lastSeenDateEdited: Int64,
    beforeDateEdited upperDateEdited: Int64,
    beforeRowID upperRowID: Int64,
    includeReceiptColumns: Bool
  ) throws -> [RetractionDetected] {
    let receiptSelection = includeReceiptColumns
      ? ", is_read, date_read, is_delivered, date_delivered"
      : ""
    let sql = """
    SELECT ROWID, guid, handle_id, date_edited\(receiptSelection)
    FROM message
    WHERE is_from_me = 0 AND date_edited != 0 AND is_empty = 1
      AND date_edited > ?1
      AND (date_edited < ?2 OR (date_edited = ?2 AND ROWID < ?3))
    ORDER BY date_edited DESC, ROWID DESC LIMIT 50;
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RetractionDetectorError.prepareFailed(sqliteMessage(database))
    }
    guard let statement else {
      throw RetractionDetectorError.prepareFailed("sqlite did not return a statement")
    }
    defer {
      sqlite3_finalize(statement)
    }

    try bind(statement, int64: lastSeenDateEdited, at: 1, database: database)
    try bind(statement, int64: upperDateEdited, at: 2, database: database)
    try bind(statement, int64: upperRowID, at: 3, database: database)

    var events: [RetractionDetected] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE {
        return events
      }
      guard result == SQLITE_ROW else {
        throw RetractionDetectorError.stepFailed(sqliteMessage(database))
      }

      let rowid = sqlite3_column_int64(statement, 0)
      let guid = sqliteText(statement, column: 1)
      let handleID = sqlite3_column_int64(statement, 2)
      let editedAt = sqlite3_column_int64(statement, 3)
      let handle = try lookupHandle(database: database, handleID: handleID) ?? String(handleID)

      var readContext: RetractionReadContext?
      if includeReceiptColumns {
        readContext = RetractionReadContext(
          isRead: sqlite3_column_int64(statement, 4) != 0,
          dateRead: sqlite3_column_int64(statement, 5),
          isDelivered: sqlite3_column_int64(statement, 6) != 0,
          dateDelivered: sqlite3_column_int64(statement, 7),
          editedAt: editedAt
        )
      }

      events.append(
        RetractionDetected(
          rowid: rowid,
          guid: guid,
          handle: handle,
          editedAt: editedAt,
          readContext: readContext,
          precedesMonitoring: didSeedFreshState && editedAt < monitoringStartedAt
        )
      )
    }
  }

  private func lookupHandle(database: OpaquePointer, handleID: Int64) throws -> String? {
    let sql = "SELECT id FROM handle WHERE ROWID = ?1 LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RetractionDetectorError.prepareFailed(sqliteMessage(database))
    }
    guard let statement else {
      throw RetractionDetectorError.prepareFailed("sqlite did not return a handle statement")
    }
    defer {
      sqlite3_finalize(statement)
    }

    try bind(statement, int64: handleID, at: 1, database: database)
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
      return sqliteText(statement, column: 0)
    }
    if result == SQLITE_DONE {
      return nil
    }

    throw RetractionDetectorError.stepFailed(sqliteMessage(database))
  }

  private func bind(
    _ statement: OpaquePointer,
    int64 value: Int64,
    at index: Int32,
    database: OpaquePointer
  ) throws {
    guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
      throw RetractionDetectorError.bindFailed(sqliteMessage(database))
    }
  }
}

private func sqliteURI(for url: URL) -> String {
  var allowedCharacters = CharacterSet.urlPathAllowed
  allowedCharacters.remove(charactersIn: "?")
  let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? url.path
  return "file:\(encodedPath)?mode=ro&immutable=0"
}

private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String {
  guard let text = sqlite3_column_text(statement, column) else {
    return ""
  }
  return String(cString: text)
}

private func sqliteMessage(_ database: OpaquePointer) -> String {
  guard let message = sqlite3_errmsg(database) else {
    return "unknown sqlite error"
  }
  return String(cString: message)
}

public func defaultMessagesChatDBURL(home: URL = imuUserHomeDirectory()) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Messages", isDirectory: true)
    .appendingPathComponent("chat.db", isDirectory: false)
}

public func defaultDetectorStateURL(home: URL = imuUserHomeDirectory()) -> URL {
  home
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("state.json", isDirectory: false)
}
