import Dispatch
import Foundation
import IMUCore

final class WatcherDaemon {
  private let queue = DispatchQueue(label: "com.imu.watcher.daemon")
  private let stopSemaphore = DispatchSemaphore(value: 0)
  private var heartbeatTimer: DispatchSourceTimer?
  private var signalSources: [DispatchSourceSignal] = []
  private var walWatcher: FSWatcher?
  private var detector: RetractionDetector?
  private var archivePipeline: ArchivePipeline?
  private var notifier: RecoveryNotifier?
  private var lastWalSize: Int64 = 0
  private var stopped = false

  func run() throws {
    let configURL = defaultConfigURL()
    let config = try ConfigStore(url: configURL).load()
    let dataDir = expandTilde(config.dataDir)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)
    archivePipeline = ArchivePipeline(
      archivesDir: dataDir.appendingPathComponent("archives", isDirectory: true),
      retentionLimit: config.archiveRetention
    )
    notifier = RecoveryNotifier(config: config.notifications)

    log("imu-watcher starting log_level=\(config.logLevel) data_dir=\(dataDir.path)")
    try startWalWatcher()
    installSignalHandlers()
    startHeartbeat()
    stopSemaphore.wait()
    log("imu-watcher stopped")
  }

  func selfTest() throws {
    let config = try ConfigStore(url: defaultConfigURL()).load()
    let dataDir = expandTilde(config.dataDir)
    let detectorResult = try runDetectorSelfTest()
    let payload = [
      "status": "ok",
      "log_level": config.logLevel,
      "data_dir": dataDir.path,
      "detector_event_count": detectorResult.eventCount,
      "detector_latency_ms": detectorResult.latencyMS
    ] as [String: Any]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "{}")
  }

  private func installSignalHandlers() {
    for signalNumber in [SIGTERM, SIGINT] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler { [weak self] in
        self?.stop(reason: "signal \(signalNumber)")
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func startHeartbeat() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .seconds(60))
    timer.setEventHandler { [weak self] in
      self?.log("heartbeat status=idle")
    }
    timer.resume()
    heartbeatTimer = timer
  }

  private func startWalWatcher() throws {
    let walURL = defaultMessagesWalURL()
    let chatDBURL = defaultMessagesChatDBURL()
    detector = try RetractionDetector(chatDBURL: chatDBURL)
    lastWalSize = FSWatcher.fileSize(at: walURL)
    let watcher = FSWatcher(walURL: walURL) { [weak self] size in
      self?.handleWalChange(size: size)
    }

    try watcher.start()
    walWatcher = watcher
    log("watching wal path=\(walURL.path) initial_size=\(lastWalSize)")
  }

  private func handleWalChange(size: Int64) {
    let delta = size - lastWalSize
    lastWalSize = size
    let deltaText = delta >= 0 ? "+\(delta)" : "\(delta)"
    log("wal change size=\(size) delta=\(deltaText)")

    guard let detector else {
      return
    }

    do {
      let events = try detector.detect()
      var processedEvents: [RetractionDetected] = []
      for event in events {
        log(
          "retraction detected rowid=\(event.rowid) guid=\(event.guid) " +
            "handle=\(event.handle) edited_at=\(event.editedAt)"
        )
        do {
          guard let archivePipeline else {
            continue
          }
          let complete = try archivePipeline.archive(event: event)
          log("recovery complete archive_dir=\(complete.archiveDir.path) recovered=\(complete.recovered)")
          notifier?.notify(complete)
          processedEvents.append(event)
        } catch {
          log("archive error rowid=\(event.rowid) error=\(error.localizedDescription)")
        }
      }
      try detector.markProcessed(processedEvents)
    } catch {
      log("detector error=\(error.localizedDescription)")
    }
  }

  private func stop(reason: String) {
    guard !stopped else {
      return
    }
    stopped = true
    heartbeatTimer?.cancel()
    walWatcher?.stop()
    walWatcher = nil
    detector = nil
    archivePipeline = nil
    notifier = nil
    log("shutdown requested reason=\(reason)")
    stopSemaphore.signal()
  }

  private func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
  }
}

private struct DetectorSelfTestResult {
  let eventCount: Int
  let latencyMS: Double
}

private enum DetectorSelfTestError: Error, LocalizedError {
  case timeout
  case noEvents
  case latencyExceeded(Double)
  case sqliteFailed(String)

  var errorDescription: String? {
    switch self {
    case .timeout:
      return "self-test timed out waiting for detector event"
    case .noEvents:
      return "self-test did not detect the synthetic retraction"
    case let .latencyExceeded(latencyMS):
      return "self-test detector latency exceeded 500 ms: \(latencyMS) ms"
    case let .sqliteFailed(message):
      return "self-test sqlite command failed: \(message)"
    }
  }
}

private func runDetectorSelfTest() throws -> DetectorSelfTestResult {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("imu-detector-self-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer {
    try? FileManager.default.removeItem(at: root)
  }

  let chatDBURL = root.appendingPathComponent("chat.db", isDirectory: false)
  let walURL = root.appendingPathComponent("chat.db-wal", isDirectory: false)
  let stateURL = root.appendingPathComponent("state.json", isDirectory: false)
  try runSQLite(
    chatDBURL,
    sql: """
    PRAGMA journal_mode=WAL;
    PRAGMA wal_autocheckpoint=0;
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT NOT NULL, service TEXT);
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY,
      guid TEXT NOT NULL,
      handle_id INTEGER,
      date_edited INTEGER,
      is_empty INTEGER,
      is_from_me INTEGER
    );
    INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550001000', 'iMessage');
    """
  )

  let detector = try RetractionDetector(
    chatDBURL: chatDBURL,
    stateStore: DetectorStateStore(url: stateURL)
  )
  let semaphore = DispatchSemaphore(value: 0)
  let lock = NSLock()
  var detectedEvents: [RetractionDetected] = []
  var callbackError: Error?
  var writeStartedAt = Date()
  var latencyMS = 0.0
  let watcher = FSWatcher(walURL: walURL, coalesceInterval: 0.05) { _ in
    do {
      let events = try detector.detect()
      guard !events.isEmpty else {
        return
      }
      try detector.markProcessed(events)
      lock.lock()
      detectedEvents = events
      latencyMS = Date().timeIntervalSince(writeStartedAt) * 1000
      lock.unlock()
      semaphore.signal()
    } catch {
      lock.lock()
      callbackError = error
      lock.unlock()
      semaphore.signal()
    }
  }
  try watcher.start()
  defer {
    watcher.stop()
  }

  let editedAt = appleEpochNanoseconds()
  writeStartedAt = Date()
  try runSQLite(
    chatDBURL,
    sql: """
    PRAGMA journal_mode=WAL;
    PRAGMA wal_autocheckpoint=0;
    INSERT INTO message (guid, handle_id, date_edited, is_empty, is_from_me)
    VALUES ('self-test-guid', 1, \(editedAt), 1, 0);
    """
  )

  guard semaphore.wait(timeout: .now() + 2) == .success else {
    throw DetectorSelfTestError.timeout
  }
  if let callbackError {
    throw callbackError
  }
  guard !detectedEvents.isEmpty else {
    throw DetectorSelfTestError.noEvents
  }
  guard latencyMS < 500 else {
    throw DetectorSelfTestError.latencyExceeded(latencyMS)
  }

  return DetectorSelfTestResult(eventCount: detectedEvents.count, latencyMS: latencyMS)
}

private func runSQLite(_ databaseURL: URL, sql: String) throws {
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [databaseURL.path, sql]
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()
  _ = stdout.fileHandleForReading.readDataToEndOfFile()

  guard process.terminationStatus == 0 else {
    let data = stderr.fileHandleForReading.readDataToEndOfFile()
    let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
    throw DetectorSelfTestError.sqliteFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

private func appleEpochNanoseconds(date: Date = Date()) -> Int64 {
  Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
}

let daemon = WatcherDaemon()

do {
  if CommandLine.arguments.contains("--self-test") {
    try daemon.selfTest()
  } else {
    try daemon.run()
  }
} catch {
  fputs("imu-watcher error: \(error.localizedDescription)\n", stderr)
  exit(1)
}
