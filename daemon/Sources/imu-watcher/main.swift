import Dispatch
import Foundation
import IMUCore

final class WatcherDaemon {
  private let queue = DispatchQueue(label: "com.imu.watcher.daemon")
  private let stopSemaphore = DispatchSemaphore(value: 0)
  private var heartbeatTimer: DispatchSourceTimer?
  private var signalSources: [DispatchSourceSignal] = []
  private var walWatcher: FSWatcher?
  private var lastWalSize: Int64 = 0
  private var stopped = false

  func run() throws {
    let configURL = defaultConfigURL()
    let config = try ConfigStore(url: configURL).load()
    let dataDir = expandTilde(config.dataDir)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

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
    let payload = [
      "status": "ok",
      "log_level": config.logLevel,
      "data_dir": dataDir.path
    ]
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
    lastWalSize = FSWatcher.fileSize(at: walURL)
    let watcher = FSWatcher(walURL: walURL) { [weak self] size in
      self?.logWalChange(size: size)
    }

    try watcher.start()
    walWatcher = watcher
    log("watching wal path=\(walURL.path) initial_size=\(lastWalSize)")
  }

  private func logWalChange(size: Int64) {
    let delta = size - lastWalSize
    lastWalSize = size
    let deltaText = delta >= 0 ? "+\(delta)" : "\(delta)"
    log("wal change size=\(size) delta=\(deltaText)")
  }

  private func stop(reason: String) {
    guard !stopped else {
      return
    }
    stopped = true
    heartbeatTimer?.cancel()
    walWatcher?.stop()
    walWatcher = nil
    log("shutdown requested reason=\(reason)")
    stopSemaphore.signal()
  }

  private func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
  }
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
