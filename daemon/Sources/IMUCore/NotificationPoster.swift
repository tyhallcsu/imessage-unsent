import Foundation
import UserNotifications

public final class NotificationPoster {
  private let config: DaemonConfig

  public init(config: DaemonConfig) {
    self.config = config
  }

  public func post(event: RetractionEvent, completion: RecoveryComplete, recoveryJSON: Data?) {
    guard config.notificationsShow else { return }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      if completion.recovered, let recoveryJSON, let text = SnapshotPipeline.recoveredText(from: recoveryJSON) {
        content.title = "Message unsent by \(event.handle)"
        let preview = String(text.prefix(max(self.config.notificationPreviewChars, 0)))
        content.body = self.config.notificationPreviewChars == 0 ? "" : "Recovered: \(preview)"
      } else {
        content.title = "Message unsent (text not recoverable)"
        content.body = completion.reason ?? "The WAL snapshot was kept for review."
      }
      content.userInfo = ["url": "imu://archive/\(completion.archiveID)"]
      let request = UNNotificationRequest(identifier: completion.archiveID, content: content, trigger: nil)
      center.add(request)
    }
  }
}
