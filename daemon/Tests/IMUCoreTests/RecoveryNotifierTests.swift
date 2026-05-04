import Foundation
import XCTest
@testable import IMUCore

final class RecoveryNotifierTests: XCTestCase {
  func testBuildsSuccessNotificationWithPreviewAndArchiveURL() throws {
    let archive = try makeArchive(
      handle: "+15550001000",
      recoveredText: "Recovered text that is longer than the preview",
      recoveryError: nil
    )
    defer {
      try? FileManager.default.removeItem(at: archive)
    }

    let notification = RecoveryNotificationBuilder(
      config: NotificationConfig(previewChars: 14)
    ).build(for: RecoveryComplete(archiveDir: archive, recovered: true))

    XCTAssertEqual(notification.title, "Message unsent by +15550001000")
    XCTAssertEqual(notification.body, "Recovered: Recovered text")
    XCTAssertEqual(notification.targetURL.scheme, "imu")
    XCTAssertEqual(notification.targetURL.host, "archive")
    XCTAssertTrue(notification.targetURL.path.contains(archive.lastPathComponent))
  }

  func testBuildsFailureNotificationWithReason() throws {
    let archive = try makeArchive(
      handle: "+15550001000",
      recoveredText: nil,
      recoveryError: "recover.sh exited 1"
    )
    defer {
      try? FileManager.default.removeItem(at: archive)
    }

    let notification = RecoveryNotificationBuilder(
      config: NotificationConfig(previewChars: 80)
    ).build(for: RecoveryComplete(archiveDir: archive, recovered: false))

    XCTAssertEqual(notification.title, "Message unsent (text not recoverable)")
    XCTAssertEqual(notification.body, "recover.sh exited 1")
  }

  func testFailureNotificationBodyUsesCategoryDisplayMessageAndHintWhenCategoryPresent() throws {
    let archive = try makeArchive(
      handle: "+15550001000",
      recoveredText: nil,
      recoveryError: "recover.sh exited 1",
      failureCategory: .walCheckpointed
    )
    defer {
      try? FileManager.default.removeItem(at: archive)
    }

    let notification = RecoveryNotificationBuilder(
      config: NotificationConfig(previewChars: 200)
    ).build(for: RecoveryComplete(archiveDir: archive, recovered: false))

    let category = RecoveryFailureCategory.walCheckpointed
    XCTAssertEqual(
      notification.body,
      "\(category.displayMessage) \(category.actionableHint!)"
    )
    XCTAssertFalse(notification.body.contains("recover.sh exited 1"))
  }

  func testFailureNotificationBodyUsesDisplayMessageAloneWhenNoActionableHint() throws {
    let archive = try makeArchive(
      handle: "+15550001000",
      recoveredText: nil,
      recoveryError: nil,
      failureCategory: .unknown
    )
    defer {
      try? FileManager.default.removeItem(at: archive)
    }

    let notification = RecoveryNotificationBuilder(
      config: NotificationConfig(previewChars: 200)
    ).build(for: RecoveryComplete(archiveDir: archive, recovered: false))

    XCTAssertEqual(notification.body, RecoveryFailureCategory.unknown.displayMessage)
  }

  func testWebhookSignatureAndRequestHeaders() {
    let body = Data("hello".utf8)
    let request = WebhookDelivery.request(
      body: body,
      webhookURL: URL(string: "https://example.test/hook")!,
      signingSecret: "secret"
    )

    XCTAssertEqual(
      WebhookDelivery.signature(body: body, secret: "secret"),
      "88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "X-Imu-Signature"),
      "88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b"
    )
  }

  func testWebhookRetriesThreeTimesWithBackoff() {
    var attempts = 0
    var delays: [TimeInterval] = []
    let delivery = WebhookDelivery(
      post: { _, _, completion in
        attempts += 1
        completion(attempts == 4)
      },
      schedule: { delay, block in
        delays.append(delay)
        block()
      }
    )

    delivery.deliver(
      body: Data(#"{"ok":true}"#.utf8),
      webhookURL: URL(string: "https://example.test/hook")!,
      signingSecret: ""
    )

    XCTAssertEqual(attempts, 4)
    XCTAssertEqual(delays, [0.5, 1.0, 2.0])
  }

  func testRecoveryNotifierPostsNativeNotificationAndWebhook() throws {
    let archive = try makeArchive(
      handle: "+15550001000",
      recoveredText: "Recovered fixture message",
      recoveryError: nil
    )
    defer {
      try? FileManager.default.removeItem(at: archive)
    }

    let poster = RecordingPoster()
    var postedRequests: [URLRequest] = []
    var postedBodies: [Data] = []
    let webhook = WebhookDelivery(
      post: { request, body, completion in
        postedRequests.append(request)
        postedBodies.append(body)
        completion(true)
      },
      schedule: { _, block in block() }
    )
    let notifier = RecoveryNotifier(
      config: NotificationConfig(
        show: true,
        previewChars: 80,
        webhook: "https://example.test/hook",
        webhookSigningSecret: "secret"
      ),
      nativePoster: poster,
      webhookDelivery: webhook
    )

    notifier.notify(RecoveryComplete(archiveDir: archive, recovered: true))

    XCTAssertEqual(poster.notifications.count, 1)
    XCTAssertEqual(poster.notifications.first?.title, "Message unsent by +15550001000")
    XCTAssertEqual(postedRequests.count, 1)
    XCTAssertEqual(postedBodies.first, poster.notifications.first?.recoveryJSON)
    XCTAssertNotNil(postedRequests.first?.value(forHTTPHeaderField: "X-Imu-Signature"))
  }

  private func makeArchive(
    handle: String,
    recoveredText: String?,
    recoveryError: String?,
    failureCategory: RecoveryFailureCategory? = nil
  ) throws -> URL {
    let archive = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-notifier-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let errorValue = recoveryError.map { $0 as Any } ?? NSNull()
    let textValue = recoveredText.map { Data($0.utf8).base64EncodedString() as Any } ?? NSNull()

    var manifestRecovery: [String: Any] = ["error": errorValue]
    if let failureCategory {
      manifestRecovery["failure_category"] = failureCategory.rawValue
    }
    let manifest: [String: Any] = [
      "handle": handle,
      "recovery": manifestRecovery
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
    try manifestData.write(to: archive.appendingPathComponent("manifest.json", isDirectory: false))

    var recovered: [String: Any] = ["text_b64": textValue]
    if let failureCategory {
      recovered["failure_category"] = failureCategory.rawValue
    }
    let recovery: [String: Any] = [
      "schema_version": 1,
      "recovered": recovered,
      "error": errorValue
    ]
    let recoveryData = try JSONSerialization.data(withJSONObject: recovery, options: [.prettyPrinted])
    try recoveryData.write(to: archive.appendingPathComponent("recovery.json", isDirectory: false))
    return archive
  }
}

private final class RecordingPoster: NativeNotificationPosting {
  var notifications: [RecoveryNotification] = []

  func post(_ notification: RecoveryNotification) {
    notifications.append(notification)
  }
}
