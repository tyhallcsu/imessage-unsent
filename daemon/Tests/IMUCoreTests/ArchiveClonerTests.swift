import XCTest
@testable import IMUCore

final class ArchiveClonerTests: XCTestCase {
  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-cloner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func testClonePreservesContents() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let source = dir.appendingPathComponent("source.bin")
    let destination = dir.appendingPathComponent("clone.bin")
    let payload = Data(repeating: 0xAB, count: 4096)
    try payload.write(to: source)

    switch ArchiveCloner.clone(from: source, to: destination) {
    case .cloned:
      XCTAssertEqual(try Data(contentsOf: destination), payload)
    case .unsupported(let err):
      throw XCTSkip("clonefile unsupported on this volume (errno=\(err))")
    case .failed(let err):
      XCTFail("clonefile failed unexpectedly: errno=\(err)")
    }
  }

  func testCloneRefusesExistingDestination() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let source = dir.appendingPathComponent("source.bin")
    let destination = dir.appendingPathComponent("dest.bin")
    try Data([0x01]).write(to: source)
    try Data([0x02]).write(to: destination)

    switch ArchiveCloner.clone(from: source, to: destination) {
    case .cloned:
      XCTFail("clonefile must not overwrite existing destination")
    case .unsupported:
      throw XCTSkip("clonefile unsupported on this volume")
    case .failed(let err):
      XCTAssertEqual(err, EEXIST, "expected EEXIST, got errno=\(err)")
    }
  }

  func testCloneFailsWhenSourceMissing() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let source = dir.appendingPathComponent("does-not-exist.bin")
    let destination = dir.appendingPathComponent("dest.bin")

    switch ArchiveCloner.clone(from: source, to: destination) {
    case .cloned, .unsupported:
      XCTFail("clonefile should not succeed when source is missing")
    case .failed(let err):
      XCTAssertEqual(err, ENOENT, "expected ENOENT, got errno=\(err)")
    }
  }
}
