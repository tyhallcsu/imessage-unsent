import Foundation
import UserNotifications

/// Watches the daemon's archives directory and posts a macOS notification
/// when a new `recovered=true` archive appears. Implements the GUI side of
/// issue #94: the daemon is a non-bundled CLI and cannot use
/// `UNUserNotificationCenter` (#65 / #87), so the GUI is the right surface
/// for end-user notifications.
///
/// Polling rather than FSEvents — keeps the implementation small and avoids
/// CFFileDescriptor lifecycle quirks. 5 s cadence is plenty: retractions
/// arrive seconds-to-minutes after the user-visible event.
public final class RecoveryWatcher {
  public typealias Notifier = (RecoveryNotificationDraft) -> Void

  private let archivesDir: URL
  private let pollInterval: TimeInterval
  private let notifier: Notifier
  private let isEnabled: () -> Bool
  private let fileManager: FileManager

  /// Highest archive id seen so far (lexicographic). Archives are named with
  /// a UTC timestamp prefix, so lex sort matches chronological order.
  private var highWaterMark: String?
  private var timer: Timer?
  /// Suppression window for "we just started; don't notify on the backlog".
  private var didSeedHighWaterMark = false

  public init(
    archivesDir: URL,
    pollInterval: TimeInterval = 5,
    fileManager: FileManager = .default,
    isEnabled: @escaping () -> Bool,
    notifier: @escaping Notifier
  ) {
    self.archivesDir = archivesDir
    self.pollInterval = pollInterval
    self.fileManager = fileManager
    self.isEnabled = isEnabled
    self.notifier = notifier
  }

  deinit {
    timer?.invalidate()
  }

  public func start() {
    seedHighWaterMark()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// Exposed for tests: pulls one cycle synchronously without scheduling.
  public func pollOnce() {
    tick()
  }

  private func seedHighWaterMark() {
    let names = readArchiveNames()
    highWaterMark = names.last
    didSeedHighWaterMark = true
  }

  private func tick() {
    guard didSeedHighWaterMark else {
      seedHighWaterMark()
      return
    }
    let names = readArchiveNames()
    let newOnes: [String]
    if let mark = highWaterMark {
      newOnes = names.filter { $0 > mark }
    } else {
      newOnes = names
    }
    if let latest = names.last {
      highWaterMark = latest
    }
    guard isEnabled() else { return }
    guard !newOnes.isEmpty else { return }

    let drafts = newOnes.compactMap { name -> RecoveryNotificationDraft? in
      let dir = archivesDir.appendingPathComponent(name, isDirectory: true)
      return loadDraft(at: dir)
    }
    let recoveredDrafts = drafts.filter { $0.recovered }

    if recoveredDrafts.count == 1, let draft = recoveredDrafts.first {
      notifier(draft)
    } else if recoveredDrafts.count > 1 {
      // Coalesce: one bundled notification per cycle.
      let bundled = RecoveryNotificationDraft(
        archiveId: recoveredDrafts.first?.archiveId ?? "",
        title: "\(recoveredDrafts.count) messages recovered",
        body: recoveredDrafts.compactMap { $0.body.isEmpty ? nil : $0.body }
          .prefix(3)
          .joined(separator: "\n"),
        recovered: true
      )
      notifier(bundled)
    }
  }

  private func readArchiveNames() -> [String] {
    guard fileManager.fileExists(atPath: archivesDir.path) else { return [] }
    let entries = (try? fileManager.contentsOfDirectory(atPath: archivesDir.path)) ?? []
    return entries
      .filter { name in
        let regex = ArchiveDirectoryNameRegex.shared
        let nsName = name as NSString
        return regex.firstMatch(in: name, range: NSRange(location: 0, length: nsName.length)) != nil
      }
      .sorted()
  }

  private func loadDraft(at dir: URL) -> RecoveryNotificationDraft? {
    let manifestURL = dir.appendingPathComponent("manifest.json", isDirectory: false)
    let recoveryURL = dir.appendingPathComponent("recovery.json", isDirectory: false)
    guard let manifestData = try? Data(contentsOf: manifestURL) else { return nil }
    guard
      let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    else {
      return nil
    }

    var recovered = false
    var body = ""
    if let recoveryData = try? Data(contentsOf: recoveryURL),
       let json = try? JSONSerialization.jsonObject(with: recoveryData) as? [String: Any],
       let recoveredField = json["recovered"] as? [String: Any],
       let textB64 = recoveredField["text_b64"] as? String,
       let bytes = Data(base64Encoded: textB64),
       let text = String(data: bytes, encoding: .utf8),
       !text.isEmpty {
      recovered = true
      body = text.prefix(120).description
    }

    let handle = (manifest["handle"] as? String) ?? "unknown"
    let title = recovered ? "Message unsent by \(handle)" : "Message unsent (text not recoverable)"

    return RecoveryNotificationDraft(
      archiveId: dir.lastPathComponent,
      title: title,
      body: body,
      recovered: recovered
    )
  }
}

public struct RecoveryNotificationDraft: Equatable {
  public let archiveId: String
  public let title: String
  public let body: String
  public let recovered: Bool

  public init(archiveId: String, title: String, body: String, recovered: Bool) {
    self.archiveId = archiveId
    self.title = title
    self.body = body
    self.recovered = recovered
  }
}

private enum ArchiveDirectoryNameRegex {
  // swiftlint:disable:next force_try
  static let shared = try! NSRegularExpression(
    pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{6}Z-\\d+$"
  )
}

/// Default notifier that posts via `UNUserNotificationCenter`. The GUI is a
/// bundled .app, so this works (unlike the daemon path that throws
/// NSException — see #65 / #87).
public func defaultRecoveryNotifier(_ draft: RecoveryNotificationDraft) {
  guard Bundle.main.bundleIdentifier != nil else { return }
  let content = UNMutableNotificationContent()
  content.title = draft.title
  content.body = draft.body
  content.sound = .default
  content.userInfo = ["archive_id": draft.archiveId]
  let request = UNNotificationRequest(
    identifier: "imu-\(UUID().uuidString)",
    content: content,
    trigger: nil
  )
  UNUserNotificationCenter.current().getNotificationSettings { settings in
    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
      return
    }
    UNUserNotificationCenter.current().add(request) { _ in }
  }
}
