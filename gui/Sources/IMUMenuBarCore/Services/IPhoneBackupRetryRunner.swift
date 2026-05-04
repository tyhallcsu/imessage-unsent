import Foundation

public enum IPhoneBackupRetryResult: Equatable {
  /// `recover.sh --include-iphone-backup` exited 0. Reload recovery.json
  /// from the archive directory to see whether it actually hit.
  case success(exitCode: Int32, durationMs: Int)
  /// `recover.sh` exited non-zero, the binary couldn't be launched, or the
  /// run timed out. The message is operator-facing.
  case failure(message: String)
}

public protocol IPhoneBackupRetryRunning {
  func run(
    archiveDir: URL,
    handle: String,
    rowid: Int64
  ) async -> IPhoneBackupRetryResult
}

public struct IPhoneBackupRetryRunner: IPhoneBackupRetryRunning {
  public let recoverScriptURL: URL
  public let timeoutSeconds: Int

  public init(
    recoverScriptURL: URL = HealthCheckPaths.standard().recoveryScript,
    timeoutSeconds: Int = 60
  ) {
    self.recoverScriptURL = recoverScriptURL
    self.timeoutSeconds = timeoutSeconds
  }

  public func run(
    archiveDir: URL,
    handle: String,
    rowid: Int64
  ) async -> IPhoneBackupRetryResult {
    let recoverURL = recoverScriptURL
    let timeout = timeoutSeconds
    return await Task.detached(priority: .userInitiated) {
      runProcess(
        recoverScriptURL: recoverURL,
        archiveDir: archiveDir,
        handle: handle,
        rowid: rowid,
        timeoutSeconds: timeout
      )
    }.value
  }
}

private func runProcess(
  recoverScriptURL: URL,
  archiveDir: URL,
  handle: String,
  rowid: Int64,
  timeoutSeconds: Int
) -> IPhoneBackupRetryResult {
  guard FileManager.default.isExecutableFile(atPath: recoverScriptURL.path) else {
    return .failure(message: "recover.sh not found or not executable at \(recoverScriptURL.path)")
  }

  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = recoverScriptURL
  process.arguments = [
    "--handle", handle,
    "--rowid", String(rowid),
    "--include-iphone-backup",
    "--json",
    "--work", archiveDir.path
  ]
  process.standardOutput = stdout
  process.standardError = stderr

  let startedAt = Date()
  do {
    try process.run()
  } catch {
    return .failure(message: "failed to launch recover.sh: \(error.localizedDescription)")
  }

  let timeoutDeadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
  while process.isRunning {
    if Date() >= timeoutDeadline {
      process.terminate()
      process.waitUntilExit()
      return .failure(message: "recover.sh timed out after \(timeoutSeconds)s")
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  process.waitUntilExit()

  let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
  let exitCode = process.terminationStatus
  if exitCode == 0 {
    return .success(exitCode: exitCode, durationMs: durationMs)
  }
  let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
  let trimmed = String(data: stderrData, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let summary = trimmed.isEmpty
    ? "recover.sh exited \(exitCode)"
    : trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
  return .failure(message: summary)
}
