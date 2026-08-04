import XCTest
@testable import IMUCore

/// Issue #160 — a fresh `DetectorState` has `lastSeenDateEdited = 0`, and the SQL
/// predicate is `date_edited > ?1`, so zero means "every retraction ever recorded".
///
/// On a real 412k-message database that produced **243 archives in 111 seconds**,
/// each cloning a ~900 MB chat.db, and recovered **nothing** — those retractions were
/// years old and their WAL pages had been checkpointed away long before the daemon
/// existed. The two live retractions after install both recovered fine.
final class FirstRunSeedingTests: XCTestCase {
  private let graceWindow: TimeInterval = 300
  private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-seed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let dir { try? FileManager.default.removeItem(at: dir) }
    dir = nil
  }

  private func makeDetector(stateURL: URL) throws -> RetractionDetector {
    try RetractionDetector(
      chatDBURL: dir.appendingPathComponent("chat.db"),
      stateStore: DetectorStateStore(url: stateURL),
      monitoringGraceWindow: graceWindow,
      now: { self.fixedNow }
    )
  }

  private var expectedSeed: Int64 {
    appleEpochNanoseconds(from: fixedNow.addingTimeInterval(-graceWindow))
  }

  // MARK: - Missing state

  func testMissingStateSeedsToGraceWindowInsteadOfZero() throws {
    let stateURL = dir.appendingPathComponent("state.json")
    let detector = try makeDetector(stateURL: stateURL)

    XCTAssertTrue(detector.didSeedFreshState)
    let persisted = try DetectorStateStore(url: stateURL).load()
    XCTAssertEqual(persisted.lastSeenDateEdited, expectedSeed)
    // The whole bug in one assertion.
    XCTAssertNotEqual(persisted.lastSeenDateEdited, 0)
  }

  func testSeedIsPersistedEvenWhenNoEventIsEverDetected() throws {
    // markProcessed() returns early on an empty event list, so if the seed were
    // only written there, a quiet first launch would leave no state at all and
    // every restart would re-baseline.
    let stateURL = dir.appendingPathComponent("state.json")
    _ = try makeDetector(stateURL: stateURL)

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: stateURL.path),
      "a launch that detects nothing must still persist its baseline"
    )
    XCTAssertEqual(try DetectorStateStore(url: stateURL).load().lastSeenDateEdited, expectedSeed)
  }

  // MARK: - Corrupt state

  func testCorruptStateAlsoSeedsAndQuarantines() throws {
    // #109 quarantines a corrupt state and returns a FRESH DetectorState — which is
    // a zeroed high-water mark, i.e. the same 243-archive excavation. Patching only
    // the missing-file branch would have left this path re-excavating.
    let stateURL = dir.appendingPathComponent("state.json")
    try Data("{ not json at all".utf8).write(to: stateURL)

    let detector = try makeDetector(stateURL: stateURL)
    XCTAssertTrue(detector.didSeedFreshState)
    XCTAssertEqual(try DetectorStateStore(url: stateURL).load().lastSeenDateEdited, expectedSeed)

    let quarantined = try FileManager.default
      .contentsOfDirectory(atPath: dir.path)
      .filter { $0.contains("corrupt") }
    XCTAssertFalse(quarantined.isEmpty, "the unreadable state should be quarantined, not deleted")
  }

  // MARK: - Existing state is sacred

  func testValidExistingStateIsNeverReseeded() throws {
    let stateURL = dir.appendingPathComponent("state.json")
    let existing = DetectorState(
      lastSeenDateEdited: 806_657_425_078_254_720,
      processedGUIDs: ["guid-a", "guid-b"],
      attemptCounts: ["guid-c": 2]
    )
    try DetectorStateStore(url: stateURL).save(existing)

    let detector = try makeDetector(stateURL: stateURL)
    XCTAssertFalse(detector.didSeedFreshState)

    let after = try DetectorStateStore(url: stateURL).load()
    XCTAssertEqual(after.lastSeenDateEdited, existing.lastSeenDateEdited)
    XCTAssertEqual(after.processedGUIDs, existing.processedGUIDs)
    XCTAssertEqual(after.attemptCounts, existing.attemptCounts)
  }

  func testStateOriginIsReported() throws {
    let stateURL = dir.appendingPathComponent("state.json")
    let store = DetectorStateStore(url: stateURL)

    XCTAssertEqual(try store.loadWithOrigin().origin, .missing)

    try store.save(DetectorState(lastSeenDateEdited: 42))
    XCTAssertEqual(try store.loadWithOrigin().origin, .existing)

    try Data("garbage".utf8).write(to: stateURL)
    XCTAssertEqual(try store.loadWithOrigin().origin, .corrupt)
  }

  // MARK: - Grace-window boundary

  func testGraceWindowBoundaryIsEnforcedBySQLNotArithmetic() throws {
    // The predicate is `date_edited > seed` (strict), so seed-1 and seed itself
    // must be excluded and only seed+1 detected. Asserting that against a real
    // database rather than against arithmetic — an earlier version of this test
    // checked `seed + 1 > seed`, which is true regardless of whether the seeding
    // works at all.
    let chatDB = dir.appendingPathComponent("chat.db")
    try makeChatDB(at: chatDB)

    let seed = expectedSeed
    try insertRetraction(into: chatDB, guid: "before-window", dateEdited: seed - 1)
    try insertRetraction(into: chatDB, guid: "exactly-at-seed", dateEdited: seed)
    try insertRetraction(into: chatDB, guid: "inside-window", dateEdited: seed + 1)

    let detector = try RetractionDetector(
      chatDBURL: chatDB,
      stateStore: DetectorStateStore(url: dir.appendingPathComponent("state.json")),
      monitoringGraceWindow: graceWindow,
      now: { self.fixedNow }
    )
    let guids = try detector.detect().map(\.guid)
    XCTAssertEqual(guids, ["inside-window"])
  }

  func testAnEventOlderThanTheWindowIsNotDetectedAtAll() throws {
    // The #160 scenario in miniature: a 2023-era retraction on a fresh install.
    let chatDB = dir.appendingPathComponent("chat.db")
    try makeChatDB(at: chatDB)
    try insertRetraction(into: chatDB, guid: "from-2023", dateEdited: 700_000_000_000_000_000)

    let detector = try RetractionDetector(
      chatDBURL: chatDB,
      stateStore: DetectorStateStore(url: dir.appendingPathComponent("state.json")),
      monitoringGraceWindow: graceWindow,
      now: { self.fixedNow }
    )
    XCTAssertEqual(try detector.detect().count, 0)
  }

  func testRestartWithValidStateDoesNotMislabelACatchUpMiss() throws {
    // A genuine wal_checkpointed miss detected after an ordinary restart must NOT
    // be relabelled predates_monitoring — that would report a real failure as
    // expected behaviour. Only a freshly seeded baseline may set the flag.
    let chatDB = dir.appendingPathComponent("chat.db")
    try makeChatDB(at: chatDB)
    let stateURL = dir.appendingPathComponent("state.json")
    // Valid pre-existing state: this daemon has run before.
    try DetectorStateStore(url: stateURL).save(DetectorState(lastSeenDateEdited: 1_000))

    // An event older than this process's start, but after the stored high-water.
    try insertRetraction(into: chatDB, guid: "catch-up", dateEdited: expectedSeed + 1)

    let detector = try RetractionDetector(
      chatDBURL: chatDB,
      stateStore: DetectorStateStore(url: stateURL),
      monitoringGraceWindow: graceWindow,
      now: { self.fixedNow }
    )
    XCTAssertFalse(detector.didSeedFreshState)
    let event = try XCTUnwrap(try detector.detect().first)
    XCTAssertEqual(event.guid, "catch-up")
    XCTAssertLessThan(event.editedAt, detector.monitoringStartedAt)
    XCTAssertFalse(
      event.precedesMonitoring,
      "an existing install's catch-up miss is a real failure, not 'we weren't watching'"
    )
  }

  func testAbsurdGraceWindowClampsInsteadOfTrapping() throws {
    // Int64(Double) traps on overflow; under launchd that is a respawn loop from a
    // config typo (the #109 failure class).
    let detector = try RetractionDetector(
      chatDBURL: dir.appendingPathComponent("chat.db"),
      stateStore: DetectorStateStore(url: dir.appendingPathComponent("state.json")),
      monitoringGraceWindow: 9_000_000_000_000_000_000,
      now: { self.fixedNow }
    )
    XCTAssertTrue(detector.didSeedFreshState)
    // Clamps to "all history" rather than crashing.
    XCTAssertEqual(
      try DetectorStateStore(url: dir.appendingPathComponent("state.json")).load().lastSeenDateEdited,
      0
    )
  }

  func testDefaultGraceWindowMatchesTheWALBufferHorizon() {
    // 5 minutes is not arbitrary — it is WALSnapshotter's rolling-buffer window,
    // i.e. the horizon in which recovery has any chance at all.
    XCTAssertEqual(RetractionDetector.defaultMonitoringGraceWindow, 300)
  }

  // MARK: - Classification

  func testEventsAreTaggedRelativeToTheMonitoringBaseline() throws {
    let detector = try makeDetector(stateURL: dir.appendingPathComponent("state.json"))
    let start = detector.monitoringStartedAt

    XCTAssertTrue(
      RetractionDetected(
        rowid: 1, guid: "old", handle: "+15550001000",
        editedAt: start - 1, precedesMonitoring: start - 1 < start
      ).precedesMonitoring
    )
    XCTAssertFalse(
      RetractionDetected(
        rowid: 2, guid: "live", handle: "+15550001000",
        editedAt: start + 1, precedesMonitoring: start + 1 < start
      ).precedesMonitoring
    )
  }

  // MARK: - Helpers

  private func makeChatDB(at url: URL) throws {
    try runSQLite(url, sql: """
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT NOT NULL, service TEXT);
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      guid TEXT NOT NULL,
      handle_id INTEGER,
      date_edited INTEGER,
      is_empty INTEGER,
      is_from_me INTEGER
    );
    INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550001000', 'iMessage');
    """)
  }

  private func insertRetraction(into url: URL, guid: String, dateEdited: Int64) throws {
    try runSQLite(url, sql: """
    INSERT INTO message (guid, handle_id, date_edited, is_empty, is_from_me)
    VALUES ('\(guid)', 1, \(dateEdited), 1, 0);
    """)
  }

  private func runSQLite(_ url: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path, sql]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testPredatesMonitoringIsADistinctCategoryInBothMirrors() {
    XCTAssertEqual(RecoveryFailureCategory.predatesMonitoring.rawValue, "predates_monitoring")
    XCTAssertNotEqual(
      RecoveryFailureCategory.predatesMonitoring.displayMessage,
      RecoveryFailureCategory.walCheckpointed.displayMessage,
      "the whole point is that these two say different things to the user"
    )
    XCTAssertTrue(RecoveryFailureCategory.allCases.contains(.predatesMonitoring))
  }
}
