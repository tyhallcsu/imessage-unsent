import Foundation
import XCTest
@testable import IMUCore

final class DaemonStatusBoardTests: XCTestCase {
  func testInitialSnapshotReflectsStartTimeAndZeroCounts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let board = DaemonStatusBoard(now: now)

    let snap = board.snapshot()

    XCTAssertEqual(snap.startedAt, now)
    XCTAssertEqual(snap.recoveryCount, 0)
    XCTAssertEqual(snap.lastWalSize, 0)
    XCTAssertNil(snap.lastWalChangeAt)
    XCTAssertNil(snap.lastError)
    XCTAssertNil(snap.chatDBReadable)
    XCTAssertNil(snap.chatDBProbedAt)
  }

  func testRecordChatDBProbeStoresLatestResult() {
    let board = DaemonStatusBoard()
    let firstProbe = Date(timeIntervalSince1970: 1_800_000_100)

    board.recordChatDBProbe(readable: false, at: firstProbe)
    var snap = board.snapshot()
    XCTAssertEqual(snap.chatDBReadable, false)
    XCTAssertEqual(snap.chatDBProbedAt, firstProbe)

    let secondProbe = Date(timeIntervalSince1970: 1_800_000_200)
    board.recordChatDBProbe(readable: true, at: secondProbe)
    snap = board.snapshot()
    XCTAssertEqual(snap.chatDBReadable, true)
    XCTAssertEqual(snap.chatDBProbedAt, secondProbe)
  }

  func testRecordStartClearsChatDBProbe() {
    let board = DaemonStatusBoard()
    board.recordChatDBProbe(readable: true)
    XCTAssertEqual(board.snapshot().chatDBReadable, true)

    board.recordStart()
    let snap = board.snapshot()
    XCTAssertNil(snap.chatDBReadable)
    XCTAssertNil(snap.chatDBProbedAt)
  }

  func testRecordWalChangeUpdatesSizeAndTimestamp() {
    let board = DaemonStatusBoard()
    let when = Date(timeIntervalSince1970: 1_800_000_500)

    board.recordWalChange(size: 4096, at: when)
    let snap = board.snapshot()

    XCTAssertEqual(snap.lastWalSize, 4096)
    XCTAssertEqual(snap.lastWalChangeAt, when)
  }

  func testRecordRecoveryClearsLastError() {
    let board = DaemonStatusBoard()
    board.recordError("transient failure")
    XCTAssertEqual(board.snapshot().lastError, "transient failure")

    board.recordRecovery()
    let snap = board.snapshot()

    XCTAssertEqual(snap.recoveryCount, 1)
    XCTAssertNil(snap.lastError)
  }

  func testRecordStartResetsState() {
    let board = DaemonStatusBoard()
    board.recordWalChange(size: 100)
    board.recordRecovery()
    board.recordError("boom")

    let restartAt = Date(timeIntervalSince1970: 1_800_001_000)
    board.recordStart(at: restartAt)
    let snap = board.snapshot()

    XCTAssertEqual(snap.startedAt, restartAt)
    XCTAssertEqual(snap.recoveryCount, 0)
    XCTAssertEqual(snap.lastWalSize, 0)
    XCTAssertNil(snap.lastWalChangeAt)
    XCTAssertNil(snap.lastError)
  }

  func testConcurrentWritersAreSerialized() {
    let board = DaemonStatusBoard()
    let iterations = 200
    let group = DispatchGroup()
    let queues = (0..<4).map { DispatchQueue(label: "writer-\($0)") }

    for queue in queues {
      group.enter()
      queue.async {
        for _ in 0..<iterations {
          board.recordRecovery()
        }
        group.leave()
      }
    }

    group.wait()

    XCTAssertEqual(board.snapshot().recoveryCount, queues.count * iterations)
  }
}
