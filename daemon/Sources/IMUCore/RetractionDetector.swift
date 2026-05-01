import Foundation

public final class RetractionDetector {
  public let databaseURL: URL
  private let stateStore: StateStore

  public init(databaseURL: URL, stateStore: StateStore) {
    self.databaseURL = databaseURL
    self.stateStore = stateStore
  }

  public func poll() throws -> [RetractionEvent] {
    var state = stateStore.load()
    let query = """
    SELECT m.ROWID, m.guid, COALESCE(h.id, ''), m.date_edited
    FROM message m
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.is_from_me = 0
      AND m.date_edited != 0
      AND m.is_empty = 1
      AND m.date_edited > \(state.lastSeenDateEdited)
    ORDER BY m.date_edited DESC LIMIT 50;
    """

    let output = try runSQLite(query: query)
    let events = output
      .split(separator: "\n")
      .compactMap { line -> RetractionEvent? in
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let rowid = Int64(parts[0]),
              let editedAt = Int64(parts[3]) else {
          return nil
        }
        return RetractionEvent(rowid: rowid, guid: String(parts[1]), handle: String(parts[2]), editedAt: editedAt)
      }

    if let maxEdited = events.map(\.editedAt).max(), maxEdited > state.lastSeenDateEdited {
      state.lastSeenDateEdited = maxEdited
      try stateStore.save(state)
    }

    return events.sorted { $0.editedAt < $1.editedAt }
  }

  private func runSQLite(query: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["-readonly", "-separator", "|", databaseURL.path, query]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let data = stderr.fileHandleForReading.readDataToEndOfFile()
      let message = String(data: data, encoding: .utf8) ?? "sqlite3 failed"
      throw NSError(domain: "IMURetractionDetector", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
