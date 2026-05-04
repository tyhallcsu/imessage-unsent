import CryptoKit
import Foundation
import UserNotifications

public struct RecoveryNotification: Equatable {
  public let title: String
  public let body: String
  public let archiveURL: URL
  public let targetURL: URL
  public let recoveryJSON: Data
}

public struct RecoveryNotificationBuilder {
  public var config: NotificationConfig

  public init(config: NotificationConfig) {
    self.config = config
  }

  public func build(for complete: RecoveryComplete) -> RecoveryNotification {
    let archiveDir = complete.archiveDir
    let recoveryJSON = (try? Data(contentsOf: archiveDir.appendingPathComponent("recovery.json"))) ?? Data()
    let manifest = readJSON(archiveDir.appendingPathComponent("manifest.json"))
    let handle = manifest["handle"] as? String ?? "unknown contact"
    let recovery = readJSONData(recoveryJSON)
    let recoveredText = recoveredText(from: recovery)
    let targetURL = archiveTargetURL(archiveDir)

    if complete.recovered, let recoveredText {
      let body = config.previewChars == 0
        ? ""
        : "Recovered: \(String(recoveredText.prefix(config.previewChars)))"
      return RecoveryNotification(
        title: "Message unsent by \(handle)",
        body: body,
        archiveURL: archiveDir,
        targetURL: targetURL,
        recoveryJSON: recoveryJSON
      )
    }

    let reason = failureReason(manifest: manifest, recovery: recovery)
    return RecoveryNotification(
      title: "Message unsent (text not recoverable)",
      body: config.previewChars == 0 ? "" : reason,
      archiveURL: archiveDir,
      targetURL: targetURL,
      recoveryJSON: recoveryJSON
    )
  }

  private func recoveredText(from recovery: [String: Any]) -> String? {
    guard
      let recovered = recovery["recovered"] as? [String: Any],
      let textB64 = recovered["text_b64"] as? String,
      let data = Data(base64Encoded: textB64),
      let text = String(data: data, encoding: .utf8),
      !text.isEmpty
    else {
      return nil
    }

    return text
  }

  private func failureReason(manifest: [String: Any], recovery: [String: Any]) -> String {
    if let category = failureCategory(manifest: manifest, recovery: recovery) {
      if let hint = category.actionableHint {
        return "\(category.displayMessage) \(hint)"
      }
      return category.displayMessage
    }
    if let error = recovery["error"] as? String, !error.isEmpty {
      return error
    }
    if
      let recoveryManifest = manifest["recovery"] as? [String: Any],
      let error = recoveryManifest["error"] as? String,
      !error.isEmpty
    {
      return error
    }
    return RecoveryFailureCategory.unknown.displayMessage
  }

  private func failureCategory(manifest: [String: Any], recovery: [String: Any]) -> RecoveryFailureCategory? {
    if
      let recovered = recovery["recovered"] as? [String: Any],
      let raw = recovered["failure_category"] as? String,
      let category = RecoveryFailureCategory(rawValue: raw)
    {
      return category
    }
    if
      let recoveryManifest = manifest["recovery"] as? [String: Any],
      let raw = recoveryManifest["failure_category"] as? String,
      let category = RecoveryFailureCategory(rawValue: raw)
    {
      return category
    }
    return nil
  }

  private func archiveTargetURL(_ archiveDir: URL) -> URL {
    var components = URLComponents()
    components.scheme = "imu"
    components.host = "archive"
    components.path = archiveDir.path
    return components.url ?? URL(string: "imu://archive")!
  }

  private func readJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url) else {
      return [:]
    }
    return readJSONData(data)
  }

  private func readJSONData(_ data: Data) -> [String: Any] {
    guard
      !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      return [:]
    }

    return json
  }
}

public protocol NativeNotificationPosting {
  func post(_ notification: RecoveryNotification)
}

public final class UserNotificationPoster: NativeNotificationPosting {
  public init() {}

  public func post(_ notification: RecoveryNotification) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else {
        return
      }

      let content = UNMutableNotificationContent()
      content.title = notification.title
      content.body = notification.body
      content.sound = .default
      content.userInfo = [
        "archive_dir": notification.archiveURL.path,
        "url": notification.targetURL.absoluteString
      ]
      let request = UNNotificationRequest(
        identifier: "imu-\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      center.add(request)
    }
  }
}

public final class WebhookDelivery {
  public typealias Post = (URLRequest, Data, @escaping (Bool) -> Void) -> Void
  public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

  private let post: Post
  private let schedule: Schedule

  public init(
    post: @escaping Post = WebhookDelivery.defaultPost,
    schedule: @escaping Schedule = WebhookDelivery.defaultSchedule
  ) {
    self.post = post
    self.schedule = schedule
  }

  public func deliver(body: Data, webhookURL: URL, signingSecret: String) {
    let request = Self.request(body: body, webhookURL: webhookURL, signingSecret: signingSecret)
    attempt(request: request, body: body, retry: 0)
  }

  public static func request(body: Data, webhookURL: URL, signingSecret: String) -> URLRequest {
    var request = URLRequest(url: webhookURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !signingSecret.isEmpty {
      request.setValue(signature(body: body, secret: signingSecret), forHTTPHeaderField: "X-Imu-Signature")
    }
    return request
  }

  public static func signature(body: Data, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let signature = HMAC<SHA256>.authenticationCode(for: body, using: key)
    return signature.map { String(format: "%02x", $0) }.joined()
  }

  private func attempt(request: URLRequest, body: Data, retry: Int) {
    post(request, body) { [weak self] succeeded in
      guard let self, !succeeded, retry < 3 else {
        return
      }

      let delay = pow(2.0, Double(retry)) * 0.5
      schedule(delay) {
        self.attempt(request: request, body: body, retry: retry + 1)
      }
    }
  }

  public static func defaultPost(request: URLRequest, body: Data, completion: @escaping (Bool) -> Void) {
    var request = request
    request.httpBody = body
    URLSession.shared.dataTask(with: request) { _, response, error in
      guard error == nil, let http = response as? HTTPURLResponse else {
        completion(false)
        return
      }
      completion((200..<300).contains(http.statusCode))
    }.resume()
  }

  public static func defaultSchedule(delay: TimeInterval, block: @escaping () -> Void) {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: block)
  }
}

public final class RecoveryNotifier {
  private let config: NotificationConfig
  private let nativePoster: NativeNotificationPosting
  private let webhookDelivery: WebhookDelivery

  public init(
    config: NotificationConfig,
    nativePoster: NativeNotificationPosting = UserNotificationPoster(),
    webhookDelivery: WebhookDelivery = WebhookDelivery()
  ) {
    self.config = config
    self.nativePoster = nativePoster
    self.webhookDelivery = webhookDelivery
  }

  public func notify(_ complete: RecoveryComplete) {
    let notification = RecoveryNotificationBuilder(config: config).build(for: complete)
    if config.show {
      nativePoster.post(notification)
    }
    if let webhookURL = URL(string: config.webhook), !config.webhook.isEmpty {
      webhookDelivery.deliver(
        body: notification.recoveryJSON,
        webhookURL: webhookURL,
        signingSecret: config.webhookSigningSecret
      )
    }
  }
}
