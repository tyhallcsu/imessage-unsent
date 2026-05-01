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

  private func runShellWriter(script: String, path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "writer", path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
