import Foundation
import XCTest
@testable import IMUCore

final class ArchiveStoreTests: XCTestCase {
  func testArchiveListReadsManifestAndRecoveryPreview() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let archive = root.appendingPathComponent("2026-05-01T120000Z-200", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = Manifest(
      detectedAt: Date(timeIntervalSince1970: 1),
      rowid: 200,
      guid: "fixture-guid",
      handle: "+15551234567",
      snapshotStartedAt: Date(timeIntervalSince1970: 1),
      snapshotFinishedAt: Date(timeIntervalSince1970: 2),
      snapFiles: [:]
    )
    try JSONEncoder.pretty.encode(manifest).write(to: archive.appendingPathComponent("manifest.json"))
    let recovery = """
    {"recovered":{"text_b64":"UmVjb3ZlcmVkIGZpeHR1cmU="},"candidate":{"rowid":200,"guid":"fixture-guid"}}
    """
    try recovery.write(to: archive.appendingPathComponent("recovery.json"), atomically: true, encoding: .utf8)

    let store = ArchiveStore(archivesDir: root)
    let response = try store.list()

    XCTAssertEqual(response.total, 1)
    XCTAssertEqual(response.archives.first?.rowid, 200)
    XCTAssertEqual(response.archives.first?.handle, "+15551234567")
    XCTAssertEqual(response.archives.first?.preview, "Recovered fixture")
  }
}
