import Foundation
import XCTest
@testable import IMUCore

final class WebhookDelivererTests: XCTestCase {
  func testSignatureUsesHMACSHA256() {
    let body = Data("The quick brown fox jumps over the lazy dog".utf8)
    let signature = WebhookDeliverer.signature(body: body, secret: "key")
    XCTAssertEqual(signature, "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
  }
}
