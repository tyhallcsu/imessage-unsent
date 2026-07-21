import Foundation
import XCTest
@testable import IMUCore

final class WALSnapshotterTests: XCTestCase {
  private var workDir: URL!
  private var walURL: URL!
  private var storeDir: URL!

  override func setUpWithError() throws {
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-walsnap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    walURL = workDir.appendingPathComponent("chat.db-wal", isDirectory: false)
    storeDir = workDir.appendingPathComponent("wal-history", isDirectory: true)
  }

  override func tearDown() {
    if let workDir {
      try? FileManager.default.removeItem(at: workDir)
    }
    workDir = nil
    walURL = nil
    storeDir = nil
  }

  func testSnapshotCreatesFileNamedAfterTimestampAndSize() throws {
    try writeWAL(bytes: 1024)
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(walURL: walURL, storeDir: storeDir, clock: clock.now)

    let dest = try XCTUnwrap(try snapper.snapshot())

    XCTAssertEqual(snapper.snapshotCount(), 1)
    XCTAssertTrue(dest.lastPathComponent.contains("-1024.db-wal"),
                  "filename should encode the WAL size: \(dest.lastPathComponent)")
    let bytes = try Data(contentsOf: dest)
    XCTAssertEqual(bytes.count, 1024)
  }

  func testSnapshotIsNoOpWhenWALSizeUnchanged() throws {
    try writeWAL(bytes: 1024)
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(walURL: walURL, storeDir: storeDir, clock: clock.now)

    _ = try snapper.snapshot()
    clock.advance(by: 1)
    let second = try snapper.snapshot()

    XCTAssertNil(second, "second snapshot at same WAL size must be a no-op")
    XCTAssertEqual(snapper.snapshotCount(), 1)
  }

  func testSnapshotCapturesNewSnapshotWhenWALSizeChanges() throws {
    try writeWAL(bytes: 1024)
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(walURL: walURL, storeDir: storeDir, clock: clock.now)

    _ = try snapper.snapshot()
    try writeWAL(bytes: 2048)
    clock.advance(by: 1)
    let second = try snapper.snapshot()

    XCTAssertNotNil(second)
    XCTAssertEqual(snapper.snapshotCount(), 2)
  }

  func testSnapshotCapturesSameSizeInPlaceContentChange() throws {
    // The #111 regression: SQLite overwrites WAL frames *in place* after a
    // checkpoint, so the file stays the same size while its content changes. A
    // size-only comparator missed this and held stale copies; the signature
    // (nanosecond mtime) must catch it.
    try writeWAL(bytes: 1024)
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(walURL: walURL, storeDir: storeDir, clock: clock.now)

    let first = try XCTUnwrap(try snapper.snapshot())

    // Same size (1024), different bytes, same inode (in place), newer mtime.
    try overwriteWALInPlace(byte: 0xCD, count: 1024, mtime: Date(timeIntervalSince1970: 1_900_000_000))
    clock.advance(by: 1)
    let second = try snapper.snapshot()

    let secondURL = try XCTUnwrap(second, "a same-size in-place WAL rewrite must produce a new snapshot")
    XCTAssertEqual(snapper.snapshotCount(), 2)
    XCTAssertNotEqual(first.lastPathComponent, secondURL.lastPathComponent)
    XCTAssertEqual(try Data(contentsOf: secondURL), Data(repeating: 0xCD, count: 1024))
  }

  func testRetentionLimitTrimsOldestSnapshots() throws {
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(
      walURL: walURL,
      storeDir: storeDir,
      retentionLimit: 2,
      clock: clock.now
    )

    for size in [1024, 2048, 3072, 4096, 5120] {
      try writeWAL(bytes: size)
      clock.advance(by: 1)
      _ = try snapper.snapshot()
    }

    XCTAssertEqual(snapper.snapshotCount(), 2,
                   "retentionLimit=2 must keep only the two most recent snapshots")
    let names = (try FileManager.default.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil))
      .map(\.lastPathComponent)
      .sorted()
    XCTAssertTrue(names.contains(where: { $0.contains("-4096.db-wal") }))
    XCTAssertTrue(names.contains(where: { $0.contains("-5120.db-wal") }))
  }

  func testMaxAgeDropsStaleSnapshots() throws {
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(
      walURL: walURL,
      storeDir: storeDir,
      retentionLimit: 100,
      maxAge: 60,
      clock: clock.now
    )

    try writeWAL(bytes: 1024)
    let oldSnap = try XCTUnwrap(try snapper.snapshot())
    // Force the oldest snapshot's mtime to a value older than maxAge.
    try FileManager.default.setAttributes(
      [.modificationDate: clock.now().addingTimeInterval(-300)],
      ofItemAtPath: oldSnap.path
    )
    try writeWAL(bytes: 2048)
    clock.advance(by: 1)
    _ = try snapper.snapshot()

    XCTAssertEqual(snapper.snapshotCount(), 1,
                   "snapshot older than maxAge must be trimmed during the next snapshot")
  }

  func testArchiveToCopiesAllFreshSnapshots() throws {
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(walURL: walURL, storeDir: storeDir, clock: clock.now)

    for size in [1024, 2048, 3072] {
      try writeWAL(bytes: size)
      clock.advance(by: 1)
      _ = try snapper.snapshot()
    }
    let dest = workDir.appendingPathComponent("archive-out", isDirectory: true)

    try snapper.archiveTo(dest)

    let copied = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".db-wal") }
    XCTAssertEqual(copied.count, 3)
  }

  /// #143 / F-M5: snapshots older than maxAge carry no forensic value for a
  /// fresh retraction — copying them into every archive multiplied disk use
  /// (retention x WAL size per archive) during quiet-then-active stretches.
  func testArchiveToSkipsSnapshotsOlderThanMaxAge() throws {
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(
      walURL: walURL,
      storeDir: storeDir,
      maxAge: 300,
      clock: clock.now
    )

    try writeWAL(bytes: 1024)
    _ = try snapper.snapshot()  // becomes stale below

    // Quiet period long past maxAge, then fresh activity. No snapshot()
    // call in between, so trim never ran and the stale file is still there.
    clock.advance(by: 1_000)
    try writeWAL(bytes: 2048)
    _ = try snapper.snapshot()

    let dest = workDir.appendingPathComponent("archive-out", isDirectory: true)
    try snapper.archiveTo(dest)

    let copied = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".db-wal") }
    XCTAssertEqual(copied.count, 1, "only the fresh snapshot belongs in the archive")
    XCTAssertTrue(copied[0].lastPathComponent.contains("-2048.db-wal"))
  }

  /// #143: without write activity, snapshot() never runs and so never trims —
  /// the heartbeat calls trimExpired() to age the buffer out during quiet
  /// periods.
  func testTrimExpiredRemovesStaleSnapshotsDuringQuietPeriods() throws {
    let clock = StubClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    let snapper = WALSnapshotter(
      walURL: walURL,
      storeDir: storeDir,
      maxAge: 300,
      clock: clock.now
    )

    try writeWAL(bytes: 1024)
    _ = try snapper.snapshot()
    XCTAssertEqual(snapper.snapshotCount(), 1)

    clock.advance(by: 100)
    snapper.trimExpired()
    XCTAssertEqual(snapper.snapshotCount(), 1, "fresh snapshots must survive the heartbeat trim")

    clock.advance(by: 500)
    snapper.trimExpired()
    XCTAssertEqual(snapper.snapshotCount(), 0, "stale snapshots must be aged out without write activity")
  }

  func testSnapshotIsNoOpWhenWALMissing() throws {
    XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
    let snapper = WALSnapshotter(walURL: walURL, storeDir: storeDir)

    let result = try snapper.snapshot()

    XCTAssertNil(result)
    XCTAssertEqual(snapper.snapshotCount(), 0)
  }

  // MARK: - Helpers

  private func writeWAL(bytes: Int) throws {
    let data = Data(repeating: 0xAB, count: bytes)
    try data.write(to: walURL, options: .atomic)
  }

  /// Overwrites the WAL in place (preserving the inode, unlike an atomic write)
  /// and pins its mtime — models SQLite rewriting frames after a checkpoint.
  private func overwriteWALInPlace(byte: UInt8, count: Int, mtime: Date) throws {
    let handle = try FileHandle(forWritingTo: walURL)
    defer { try? handle.close() }
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(repeating: byte, count: count))
    try handle.synchronize()
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: walURL.path)
  }
}

private final class StubClock {
  private var current: Date

  init(start: Date) {
    current = start
  }

  func now() -> Date { current }

  func advance(by seconds: TimeInterval) {
    current = current.addingTimeInterval(seconds)
  }
}
