import Foundation

public enum IPhoneBackupRetryResult: Equatable {
  /// `recover.sh --include-iphone-backup` exited 0 and `recovery.json`
  /// now contains recovered text.
  case found(detail: RecoveryDetail, durationMs: Int)
  /// `recover.sh --include-iphone-backup` exited 0, but `recovery.json`
  /// still does not contain recovered text.
  case noMatch(detail: RecoveryDetail, durationMs: Int)
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
    recoverScriptURL: URL = HealthCheckPaths.defaults().recoveryScript,
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
    return .failure(message: "recover.sh not found or not executable")
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
    return .failure(message: shortMessage("Could not launch recover.sh: \(error.localizedDescription)",
                                         fallback: "Could not launch recover.sh"))
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
  let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
  let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
  let exitCode = process.terminationStatus
  if exitCode == 0 {
    do {
      let detail = try FileSystemRecoveryDetailLoader().load(archiveDir: archiveDir)
      if detail.recovered {
        return .found(detail: detail, durationMs: durationMs)
      }
      return .noMatch(detail: detail, durationMs: durationMs)
    } catch {
      return .failure(message: "Retry finished, but recovery results could not be reloaded")
    }
  }
  return .failure(message: shortProcessMessage(
    stdoutData: stdoutData,
    stderrData: stderrData,
    exitCode: exitCode
  ))
}

private func shortProcessMessage(
  stdoutData: Data,
  stderrData: Data,
  exitCode: Int32
) -> String {
  let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
  let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
  let candidate = lastNonEmptyLine(in: stderrText)
    ?? lastNonEmptyLine(in: stdoutText)
    ?? ""
  return shortMessage(candidate, fallback: "recover.sh exited \(exitCode)")
}

private func lastNonEmptyLine(in text: String) -> String? {
  text
    .split(separator: "\n")
    .map(String.init)
    .reversed()
    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func shortMessage(_ raw: String, fallback: String) -> String {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return fallback }
  if trimmed.count <= 160 { return trimmed }
  return String(trimmed.prefix(157)) + "..."
}
