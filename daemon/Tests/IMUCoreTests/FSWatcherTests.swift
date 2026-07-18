import Foundation
import XCTest
@testable import IMUCore

final class FSWatcherTests: XCTestCase {
  func testSeparateProcessWriteFiresCallbackWithFileSize() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-fswatcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let walURL = directory.appendingPathComponent("chat.db-wal", isDirectory: false)
    XCTAssertTrue(FileManager.default.createFile(atPath: walURL.path, contents: Data()))

    let callbackFired = expectation(description: "FSEvents callback fires for a WAL write")
    let lock = NSLock()
    var observedSizes: [Int64] = []
    let watcher = FSWatcher(walURL: walURL, coalesceInterval: 0.05) { size in
      lock.withLock {
        observedSizes.append(size)
      }
      if size == 17 {
        callbackFired.fulfill()
      }
    }

    try watcher.start()
    defer {
      watcher.stop()
    }

    try runShellWriter(script: "printf 'synthetic-wal-hit' >> \"$1\"", path: walURL.path)

    wait(for: [callbackFired], timeout: 5)
    lock.withLock {
      XCTAssertTrue(observedSizes.contains(17))
    }
  }

  func testDeleteAndRecreateStillFiresCallback() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-fswatcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let walURL = directory.appendingPathComponent("chat.db-wal", isDirectory: false)
    XCTAssertTrue(FileManager.default.createFile(atPath: walURL.path, contents: Data("old".utf8)))

    let callbackFired = expectation(description: "FSEvents callback fires after recreate")
    let lock = NSLock()
    var observedSizes: [Int64] = []
    let watcher = FSWatcher(walURL: walURL, coalesceInterval: 0.05) { size in
      lock.withLock {
        observedSizes.append(size)
      }
      if size == 7 {
        callbackFired.fulfill()
      }
    }

    try watcher.start()
    defer {
      watcher.stop()
    }

    try runShellWriter(
      script: "rm -f \"$1\"\nsleep 0.1\nprintf 'new-wal' > \"$1\"",
      path: walURL.path
    )

    wait(for: [callbackFired], timeout: 5)
    lock.withLock {
      XCTAssertTrue(observedSizes.contains(7))
    }
  }

  /// Issue #59: FSEvents on `~/Library/Messages` is unreliable for high-
  /// frequency `chat.db-wal` writes. The polling fallback must detect a size
  /// change even when FSEvents never delivers an event for it.
  func testPollingFallbackDetectsSizeChangeWhenFSEventsDisabled() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-fswatcher-poll-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let walURL = directory.appendingPathComponent("chat.db-wal", isDirectory: false)
    XCTAssertTrue(FileManager.default.createFile(atPath: walURL.path, contents: Data("seed".utf8)))

    let pollFired = expectation(description: "polling fallback observes the size change")
    let lock = NSLock()
    var observedSizes: [Int64] = []
    let watcher = FSWatcher(
      walURL: walURL,
      coalesceInterval: 0.05,
      pollInterval: 0.1,
      enableFSEvents: false
    ) { size in
      lock.withLock {
        observedSizes.append(size)
      }
      if size == 15 {
        pollFired.fulfill()
      }
    }

    try watcher.start()
    defer {
      watcher.stop()
    }

    // Write directly via FileHandle. FSEvents is disabled for this test, so
    // the only path that can detect this change is the 100ms polling timer.
    let handle = try FileHandle(forWritingTo: walURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("-after-seed".utf8))
    try handle.close()

    wait(for: [pollFired], timeout: 3)
    lock.withLock {
      XCTAssertTrue(observedSizes.contains(15))
    }
  }

  /// Both FSEvents and the polling timer share `lastReportedSize` for dedupe.
  /// After a single write, the handler must fire exactly once even though the
  /// poll keeps running.
  func testPollingDoesNotRefireAfterSizeIsReported() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-fswatcher-dedup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let walURL = directory.appendingPathComponent("chat.db-wal", isDirectory: false)
    XCTAssertTrue(FileManager.default.createFile(atPath: walURL.path, contents: Data()))

    let lock = NSLock()
    var fireCount = 0
    let watcher = FSWatcher(
      walURL: walURL,
      coalesceInterval: 0.05,
      pollInterval: 0.1,
      enableFSEvents: false
    ) { _ in
      lock.withLock {
        fireCount += 1
      }
    }

    try watcher.start()
    defer {
      watcher.stop()
    }

    let handle = try FileHandle(forWritingTo: walURL)
    try handle.write(contentsOf: Data("once".utf8))
    try handle.close()

    // Wait long enough for several poll cycles after the size has stabilised.
    Thread.sleep(forTimeInterval: 0.6)

    lock.withLock {
      XCTAssertEqual(fireCount, 1, "handler must fire exactly once per distinct size")
    }
  }

  /// #111: SQLite overwrites WAL frames in place after a checkpoint, leaving
  /// the file the same size. The polling fallback must detect that via the
  /// change signature (mtime), not size alone. FSEvents is disabled so the
  /// poll is the only thing that could catch it.
  func testPollingFallbackDetectsSameSizeInPlaceChange() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-fswatcher-inplace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let walURL = directory.appendingPathComponent("chat.db-wal", isDirectory: false)
    XCTAssertTrue(FileManager.default.createFile(atPath: walURL.path, contents: Data(repeating: 0x41, count: 8)))

    let fired = expectation(description: "poll detects a same-size in-place change")
    let lock = NSLock()
    var fireCount = 0
    let watcher = FSWatcher(
      walURL: walURL,
      coalesceInterval: 0.05,
      pollInterval: 0.1,
      enableFSEvents: false
    ) { size in
      lock.withLock { fireCount += 1 }
      if size == 8 {
        fired.fulfill()
      }
    }

    try watcher.start()
    defer {
      watcher.stop()
    }

    // Same size (8 bytes), different content, in place (same inode), new mtime.
    let handle = try FileHandle(forWritingTo: walURL)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(repeating: 0x42, count: 8))
    try handle.close()
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
      ofItemAtPath: walURL.path
    )

    wait(for: [fired], timeout: 3)
    lock.withLock {
      XCTAssertGreaterThanOrEqual(fireCount, 1, "same-size in-place change must fire the poll")
    }
  }

  private func runShellWriter(script: String, path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "writer", path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
