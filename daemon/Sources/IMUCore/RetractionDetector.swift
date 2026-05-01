import Foundation
import SQLite3

public struct RetractionDetected: Equatable {
  public let rowid: Int64
  public let guid: String
  public let handle: String
  public let editedAt: Int64

  public init(rowid: Int64, guid: String, handle: String, editedAt: Int64) {
    self.rowid = rowid
    self.guid = guid
    self.handle = handle
    self.editedAt = editedAt
  }
}

public struct DetectorState: Codable, Equatable {
  public var lastSeenDateEdited: Int64

  public init(lastSeenDateEdited: Int64 = 0) {
    self.lastSeenDateEdited = lastSeenDateEdited
  }

  enum CodingKeys: String, CodingKey {
    case lastSeenDateEdited = "last_seen_date_edited"
  }
}

public struct DetectorStateStore {
  public let url: URL

  public init(url: URL = defaultDetectorStateURL()) {
    self.url = url
  }

  public func load() throws -> DetectorState {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return DetectorState()
    }

    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(DetectorState.self, from: data)
  }

  public func save(_ state: DetectorState) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: url, options: .atomic)
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
  private let chatDBURL: URL
  private let stateStore: DetectorStateStore
  private var state: DetectorState

  public init(
    chatDBURL: URL = defaultMessagesChatDBURL(),
    stateStore: DetectorStateStore = DetectorStateStore()
  ) throws {
    self.chatDBURL = chatDBURL
    self.stateStore = stateStore
    self.state = try stateStore.load()
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

    return try queryRetractions(database: database, after: state.lastSeenDateEdited)
  }

  public func markProcessed(_ events: [RetractionDetected]) throws {
    guard let maxEditedAt = events.map(\.editedAt).max(), maxEditedAt > state.lastSeenDateEdited else {
      return
    }

    state.lastSeenDateEdited = maxEditedAt
    try stateStore.save(state)
  }

  public func currentState() -> DetectorState {
    state
  }

  private func queryRetractions(database: OpaquePointer, after lastSeenDateEdited: Int64) throws -> [RetractionDetected] {
    var events: [RetractionDetected] = []
    var upperDateEdited = Int64.max
    var upperRowID = Int64.max

    while true {
      let page = try queryRetractionPage(
        database: database,
        after: lastSeenDateEdited,
        beforeDateEdited: upperDateEdited,
        beforeRowID: upperRowID
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
    beforeRowID upperRowID: Int64
  ) throws -> [RetractionDetected] {
    let sql = """
    SELECT ROWID, guid, handle_id, date_edited
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

      events.append(
        RetractionDetected(rowid: rowid, guid: guid, handle: handle, editedAt: editedAt)
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

public func defaultMessagesChatDBURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Messages", isDirectory: true)
    .appendingPathComponent("chat.db", isDirectory: false)
}

public func defaultDetectorStateURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
  home
    .appendingPathComponent(".config", isDirectory: true)
    .appendingPathComponent("imessage-unsent", isDirectory: true)
    .appendingPathComponent("state.json", isDirectory: false)
}
