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
    // expected behaviour. Only a fresh-state launch may set the flag.
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
      "without a fresh-state launch we cannot infer predates_monitoring: the daemon may or may not have been running, so the category must not be claimed"
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
    // i.e. the span of WAL history we retain ourselves. Not a recoverability
    // limit: the live WAL can hold older frames.
    XCTAssertEqual(RetractionDetector.defaultMonitoringGraceWindow, 300)
  }

  // MARK: - Classification

  func testEventsAreTaggedRelativeToTheMonitoringStartInstant() throws {
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

// MARK: - Reclassification boundaries (issue #160, Codex [6] item 9)

extension FirstRunSeedingTests {
  /// `predates_monitoring` must replace only the categories that mean "we didn't
  /// see it in the WAL, cause unspecified". Every other category is a specific
  /// finding that is true regardless of when we started watching, and silently
  /// overwriting it would destroy the diagnosis.
  func testOnlyGenericMissesAreReclassified() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-reclass-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    // Categories that are specific findings, independent of monitoring start.
    for preserved in [
      RecoveryFailureCategory.notInLocalWAL,
      .scriptError,
      .unknownHandle,
      .attachmentOnly
    ] {
      let complete = try runPipeline(
        root: root, liveDir: liveDir, precedesMonitoring: true,
        script: failingScript(category: preserved.rawValue)
      )
      XCTAssertEqual(
        try manifestCategory(complete.archiveDir), preserved.rawValue,
        "\(preserved.rawValue) is a specific diagnosis and must survive"
      )
    }

    // The generic misses DO become predates_monitoring.
    for generic in [RecoveryFailureCategory.walCheckpointed, .unknown] {
      let complete = try runPipeline(
        root: root, liveDir: liveDir, precedesMonitoring: true,
        script: failingScript(category: generic.rawValue)
      )
      XCTAssertEqual(try manifestCategory(complete.archiveDir), "predates_monitoring")
    }

    // …but only when the event actually predates monitoring.
    let watched = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: false,
      script: failingScript(category: "wal_checkpointed")
    )
    XCTAssertEqual(try manifestCategory(watched.archiveDir), "wal_checkpointed")
  }

  func testSuccessfulRecoveryIsNeverReclassified() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-reclass-ok-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    // A pre-monitoring event can still succeed if the page happens to be in the
    // live WAL — the 5-minute window is a policy bound, not a proof.
    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: true,
      script: #"""
      #!/usr/bin/env bash
      echo '{"schema_version":1,"recovered":{"text_b64":"aGVsbG8="}}'
      """#
    )
    XCTAssertTrue(complete.recovered)
    XCTAssertNil(try manifestCategory(complete.archiveDir))
  }

  private func failingScript(category: String) -> String {
    """
    #!/usr/bin/env bash
    echo '{"schema_version":1,"recovered":{"text_b64":null,"failure_category":"\(category)"}}'
    """
  }

  private func runPipeline(
    root: URL, liveDir: URL, precedesMonitoring: Bool, script: String
  ) throws -> RecoveryComplete {
    let scriptURL = root.appendingPathComponent("recover-\(UUID().uuidString).sh", isDirectory: false)
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let pipeline = ArchivePipeline(
      liveMessagesDir: liveDir,
      archivesDir: root.appendingPathComponent("archives", isDirectory: true),
      recoverScriptURL: scriptURL,
      retentionLimit: 500
    )
    return try pipeline.archive(
      event: RetractionDetected(
        rowid: Int64.random(in: 1...1_000_000),
        guid: UUID().uuidString,
        handle: "+15550001000",
        editedAt: 797_000_010_000_000_000,
        precedesMonitoring: precedesMonitoring
      )
    )
  }

  /// The category as every real consumer sees it. ArchiveHistoryReader, the
  /// notifier/webhook payload and the GUI detail loader all prefer recovery.json
  /// over the manifest, so a reclassification that only reached the manifest was
  /// invisible to the user (Codex [16] item 14).
  private func recoveryJSONCategory(_ archiveDir: URL) throws -> String? {
    let data = try Data(contentsOf: archiveDir.appendingPathComponent("recovery.json"))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let recovered = object["recovered"] as? [String: Any]
    return recovered?["failure_category"] as? String
  }

  private func manifestCategory(_ archiveDir: URL) throws -> String? {
    let data = try Data(contentsOf: archiveDir.appendingPathComponent("manifest.json"))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let recovery = object["recovery"] as? [String: Any]
    return recovery?["failure_category"] as? String
  }
}


// MARK: - The category the user actually sees (Codex [16] item 14)

extension FirstRunSeedingTests {
  func testReclassificationReachesRecoveryJSONNotJustTheManifest() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-consumer-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: true,
      script: failingScript(category: "wal_checkpointed")
    )

    // Both artifacts must agree, or the History list, the notification, the
    // webhook payload and the GUI detail pane all keep showing the old story.
    XCTAssertEqual(try manifestCategory(complete.archiveDir), "predates_monitoring")
    XCTAssertEqual(try recoveryJSONCategory(complete.archiveDir), "predates_monitoring")
  }

  func testRewriteLeavesEveryOtherRecoveryJSONFieldIntact() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-consumer2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: true,
      script: #"""
      #!/usr/bin/env bash
      echo '{"schema_version":1,"error":"kept","recovered":{"text_b64":null,"length":null,"failure_category":"wal_checkpointed"}}'
      """#
    )

    let data = try Data(contentsOf: complete.archiveDir.appendingPathComponent("recovery.json"))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["schema_version"] as? Int, 1)
    XCTAssertEqual(object["error"] as? String, "kept")
    let recovered = try XCTUnwrap(object["recovered"] as? [String: Any])
    XCTAssertEqual(recovered["failure_category"] as? String, "predates_monitoring")
    XCTAssertTrue(recovered.keys.contains("text_b64"))
    XCTAssertTrue(recovered.keys.contains("length"))
  }

  func testWatchedMissKeepsItsCategoryInRecoveryJSONToo() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-consumer3-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: false,
      script: failingScript(category: "wal_checkpointed")
    )
    XCTAssertEqual(try recoveryJSONCategory(complete.archiveDir), "wal_checkpointed")
  }
}

// MARK: - Real consumers, not just the file (Codex [18] item 16)

extension FirstRunSeedingTests {
  /// Parsing recovery.json myself proves the bytes are right; it does not prove the
  /// components the user actually sees agree. These drive the real consumers.
  func testHistoryReaderAndNotifierBothReportPredatesMonitoring() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-consumers-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let archivesDir = root.appendingPathComponent("archives", isDirectory: true)
    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: true,
      script: failingScript(category: "wal_checkpointed")
    )

    // 1. The History list (menu bar + `recent` control-socket op).
    let entries = ArchiveHistoryReader(archivesDir: archivesDir).recent(limit: 10)
    let archiveName = complete.archiveDir.lastPathComponent
    let entry = try XCTUnwrap(entries.first { $0.archivePath.hasSuffix(archiveName) })
    XCTAssertEqual(entry.failureCategory, .predatesMonitoring)
    XCTAssertFalse(entry.recovered)

    // 2. The notification, and the webhook body built from the same payload.
    let notification = RecoveryNotificationBuilder(config: NotificationConfig())
      .build(for: complete)
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: notification.recoveryJSON) as? [String: Any]
    )
    let recovered = try XCTUnwrap(payload["recovered"] as? [String: Any])
    XCTAssertEqual(
      recovered["failure_category"] as? String, "predates_monitoring",
      "the webhook ships recovery.json verbatim — a stale category would leak to subscribers"
    )

    // 3. The user-visible notification text itself, which is built from the
    // category rather than from the JSON blob.
    // The builder renders "<displayMessage> <actionableHint>".
    let category = RecoveryFailureCategory.predatesMonitoring
    XCTAssertTrue(
      notification.body.contains(category.displayMessage),
      "the banner must say what happened, not the generic 'cause not determined'"
    )
    XCTAssertTrue(notification.body.contains(try XCTUnwrap(category.actionableHint)))
    XCTAssertFalse(
      notification.body.contains(RecoveryFailureCategory.walCheckpointed.displayMessage)
    )
  }

  func testHistoryReaderKeepsWalCheckpointedForAWatchedMiss() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-consumers2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: false,
      script: failingScript(category: "wal_checkpointed")
    )
    let entries = ArchiveHistoryReader(
      archivesDir: root.appendingPathComponent("archives", isDirectory: true)
    ).recent(limit: 10)
    let archiveName = complete.archiveDir.lastPathComponent
    let entry = try XCTUnwrap(entries.first { $0.archivePath.hasSuffix(archiveName) })
    XCTAssertEqual(entry.failureCategory, .walCheckpointed)
  }
}

// MARK: - Forward compatibility (Codex [24] item 19)

extension FirstRunSeedingTests {
  /// A category this build doesn't know maps to `.unknown` on the enum — but it is
  /// NOT the literal "unknown" diagnosis, and converting it to predates_monitoring
  /// would erase information from a newer recover.sh that we simply can't parse yet.
  func testUnrecognizedFutureCategoryIsPreservedNotReclassified() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-forward-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: true,
      script: failingScript(category: "some_future_diagnosis_v7")
    )

    XCTAssertEqual(
      try recoveryJSONCategory(complete.archiveDir), "some_future_diagnosis_v7",
      "an unparseable category must survive verbatim for a newer reader"
    )
    XCTAssertNotEqual(try recoveryJSONCategory(complete.archiveDir), "predates_monitoring")
  }

  func testLiteralUnknownStillReclassifies() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-forward2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let liveDir = root.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
    try Data("synthetic db".utf8)
      .write(to: liveDir.appendingPathComponent("chat.db", isDirectory: false))

    let complete = try runPipeline(
      root: root, liveDir: liveDir, precedesMonitoring: true,
      script: failingScript(category: "unknown")
    )
    XCTAssertEqual(try recoveryJSONCategory(complete.archiveDir), "predates_monitoring")
  }
}
