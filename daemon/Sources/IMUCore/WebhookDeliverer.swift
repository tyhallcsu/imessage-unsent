import CryptoKit
import Foundation

public final class WebhookDeliverer {
  private let config: DaemonConfig
  private let queue = DispatchQueue(label: "com.imessage-unsent.webhook", qos: .utility)

  public init(config: DaemonConfig) {
    self.config = config
  }

  public func deliver(recoveryJSON: Data) {
    guard !config.webhook.isEmpty,
          let url = URL(string: config.webhook) else {
      return
    }

    queue.async { [config] in
      for attempt in 0..<3 {
        if Self.post(body: recoveryJSON, to: url, secret: config.webhookSigningSecret) {
          return
        }
        Thread.sleep(forTimeInterval: pow(2.0, Double(attempt)) * 0.5)
      }
    }
  }

  public static func signature(body: Data, secret: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let code = HMAC<SHA256>.authenticationCode(for: body, using: key)
    return "sha256=" + code.map { String(format: "%02x", $0) }.joined()
  }

  private static func post(body: Data, to url: URL, secret: String) -> Bool {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("imessage-unsent/\(imuVersion)", forHTTPHeaderField: "User-Agent")
    if !secret.isEmpty {
      request.setValue(signature(body: body, secret: secret), forHTTPHeaderField: "X-Imu-Signature")
    }

    let semaphore = DispatchSemaphore(value: 0)
    var success = false
    URLSession.shared.dataTask(with: request) { _, response, _ in
      if let http = response as? HTTPURLResponse {
        success = (200..<300).contains(http.statusCode)
      }
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 10)
    return success
  }
}
