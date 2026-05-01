import Foundation

public struct IMUPaths: Sendable {
  public var home: URL
  public var configFile: URL
  public var dataDir: URL
  public var archivesDir: URL
  public var socketFile: URL
  public var stateFile: URL
  public var logFile: URL
  public var messagesDir: URL
  public var recoverScript: URL

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    repoRoot: URL? = nil
  ) {
    let configBase = home.appendingPathComponent(".config/imessage-unsent", isDirectory: true)
    let dataBase = home.appendingPathComponent("Library/Application Support/imessage-unsent", isDirectory: true)
    let logBase = home.appendingPathComponent("Library/Logs/imessage-unsent", isDirectory: true)
    let root = repoRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    self.home = home
    self.configFile = configBase.appendingPathComponent("config.toml")
    self.dataDir = dataBase
    self.archivesDir = dataBase.appendingPathComponent("archives", isDirectory: true)
    self.socketFile = dataBase.appendingPathComponent("daemon.sock")
    self.stateFile = configBase.appendingPathComponent("state.json")
    self.logFile = logBase.appendingPathComponent("watcher.log")
    self.messagesDir = home.appendingPathComponent("Library/Messages", isDirectory: true)
    self.recoverScript = root.appendingPathComponent("scripts/recover.sh")
  }

  public func ensureDirectories() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: archivesDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
}
