import Foundation
import IMUCore

final class WatcherApp {
  private var paths = IMUPaths()
  private var config = DaemonConfig()
  private var watcher: FSWatcher?
  private var server: UnixSocketServer?
  private var watching = false

  func run() throws {
    try paths.ensureDirectories()
    let store = ConfigStore(url: paths.configFile)
    config = try store.load()
    paths.messagesDir = expandTilde(config.messagesDir)
    paths.dataDir = expandTilde(config.dataDir)
    paths.archivesDir = paths.dataDir.appendingPathComponent("archives", isDirectory: true)
    paths.socketFile = paths.dataDir.appendingPathComponent("daemon.sock")
    if !FileManager.default.fileExists(atPath: paths.recoverScript.path) {
      paths.recoverScript = paths.dataDir.appendingPathComponent("scripts/recover.sh")
    }
    try paths.ensureDirectories()

    let archiveStore = ArchiveStore(archivesDir: paths.archivesDir)
    let router = APIRouter(archiveStore: archiveStore) { [weak self] in
      WatchStatus(
        status: self?.watching == true ? "watching" : "idle",
        watching: self?.watching == true,
        socketPath: self?.paths.socketFile.path ?? "",
        archiveCount: archiveStore.count()
      )
    }
    server = UnixSocketServer(socketURL: paths.socketFile) { request in
      router.route(request)
    }
    try server?.start()

    let detector = RetractionDetector(
      databaseURL: paths.messagesDir.appendingPathComponent("chat.db"),
      stateStore: StateStore(url: paths.stateFile)
    )
    let pipeline = SnapshotPipeline(paths: paths, config: config)
    let notifier = NotificationPoster(config: config)
    let webhookDeliverer = WebhookDeliverer(config: config)
    watcher = FSWatcher(watchedFile: paths.messagesDir.appendingPathComponent("chat.db-wal")) { [weak self] change in
      self?.log("wal change size=\(change.size) delta=\(change.delta)")
      do {
        let filter = EventFilter(allow: self?.config.filterAllow ?? [], deny: self?.config.filterDeny ?? [])
        let events = try detector.poll().filter { filter.allows($0) }
        for event in events {
          self?.log("retraction rowid=\(event.rowid) guid=\(event.guid)")
          let completion = try pipeline.run(event: event)
          let recoveryURL = URL(fileURLWithPath: completion.archiveDir).appendingPathComponent("recovery.json")
          let recoveryJSON = try? Data(contentsOf: recoveryURL)
          notifier.post(event: event, completion: completion, recoveryJSON: recoveryJSON)
          if let recoveryJSON {
            webhookDeliverer.deliver(recoveryJSON: recoveryJSON)
          }
        }
      } catch {
        self?.log("detector error: \(error.localizedDescription)")
      }
    }
    try watcher?.start()
    watching = true
    log("imu-watcher started")

    signal(SIGTERM) { _ in
      exit(0)
    }

    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      self?.log("heartbeat status=\(self?.watching == true ? "watching" : "idle")")
    }
    RunLoop.main.run()
  }

  func selfTest() throws {
    let status = WatchStatus(status: "self-test", watching: false, socketPath: paths.socketFile.path, archiveCount: 0)
    let data = try JSONEncoder.pretty.encode(status)
    print(String(data: data, encoding: .utf8) ?? "{}")
  }

  private func log(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    if let data = line.data(using: .utf8) {
      if FileManager.default.fileExists(atPath: paths.logFile.path),
         let handle = try? FileHandle(forWritingTo: paths.logFile) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
      } else {
        try? data.write(to: paths.logFile)
      }
    }
    fputs(line, stderr)
  }

}

let app = WatcherApp()
do {
  if CommandLine.arguments.contains("--self-test") {
    try app.selfTest()
  } else {
    try app.run()
  }
} catch {
  fputs("imu-watcher error: \(error.localizedDescription)\n", stderr)
  exit(1)
}
