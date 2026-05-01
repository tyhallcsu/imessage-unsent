import Foundation
import XCTest
@testable import IMUMenuBarCore

final class DaemonClientTests: XCTestCase {
  func testArchivesDecodeFromTransport() throws {
    let data = """
    {
      "page": 1,
      "limit": 5,
      "total": 1,
      "archives": [
        {
          "id": "2026-05-01T120000Z-200",
          "rowid": 200,
          "handle": "+15551234567",
          "guid": "fixture-guid",
          "detectedAt": "2026-05-01T12:00:00Z",
          "recovered": true,
          "preview": "Recovered fixture",
          "archiveDir": "/tmp/archive"
        }
      ]
    }
    """.data(using: .utf8)!
    let client = DaemonClient(transport: MockTransport(responses: ["GET /archives?page=1&limit=5": data]))
    let response = try client.archives(page: 1, limit: 5)
    XCTAssertEqual(response.total, 1)
    XCTAssertEqual(response.archives.first?.preview, "Recovered fixture")
  }
}
