import CryptoKit
import Foundation

/// The daemon's own log file, with handle redaction and size-bounded rotation.
///
/// Issue #174. Previously `log()` printed to stdout and launchd redirected that to
/// `watcher.log` via `StandardOutPath`. Two consequences:
///
/// 1. Every detected retraction wrote `handle=+1XXXXXXXXXX` in the clear. On one
///    real install that was 242 correspondent phone numbers, with timestamps, in a
///    file `make doctor` reads and Time Machine backs up — in a project that
///    rewrote its git history to scrub PII.
/// 2. Rotation was impossible. launchd owns that file descriptor, so renaming the
///    file just moves the inode the daemon keeps writing into, and whether
///    truncate-in-place works depends on undocumented `O_APPEND` behaviour. The
///    log had reached 1.3 MB with exactly one generation — i.e. never rotated.
///
/// So the daemon opens and owns the file itself. The LaunchAgent's stdout/stderr go
/// to a separate `watcher.err.log`, which only receives crash and runtime output.
public final class DaemonLog {
  /// Rotate when the file exceeds this. One generation is kept (`.1`).
  public static let defaultMaxBytes: Int = 4 * 1024 * 1024

  private let fileURL: URL
  private let saltURL: URL
  private let maxBytes: Int
  private let redact: Bool
  private let queue = DispatchQueue(label: "com.imu.watcher.log")
  private lazy var salt: Data = Self.loadOrCreateSalt(at: saltURL)
  private var enforcedMode = false

  public init(
    fileURL: URL,
    saltURL: URL,
    maxBytes: Int = DaemonLog.defaultMaxBytes,
    redact: Bool = true
  ) {
    self.fileURL = fileURL
    self.saltURL = saltURL
    self.maxBytes = maxBytes
    self.redact = redact
  }

  public func write(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] "
      + (redact ? Self.redactIdentifiers(in: message, salt: salt) : message)
      + "\n"
    queue.sync {
      rotateIfNeeded()
      append(line)
    }
    // Also to stdout so `--self-test`, a foreground run, and the E2E harness all
    // still see output. launchd sends that to watcher.err.log, which is bounded by
    // being near-empty in normal operation.
    print(line, terminator: "")
    fflush(stdout)
  }

  // MARK: - Redaction

  /// Phone numbers and Apple ID emails, wherever they appear in a line.
  ///
  /// A scrubber rather than redaction at each call site, deliberately: call-site
  /// redaction leaks the first time someone adds a log statement and forgets. This
  /// is the same reasoning that killed the allowlist design in #25.
  static func redactIdentifiers(in message: String, salt: Data) -> String {
    var out = message
    for pattern in [
      #"\+[0-9]{7,15}"#,                                    // E.164
      #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#    // Apple ID email
    ] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out))
      // Replace back-to-front so earlier ranges stay valid.
      for match in matches.reversed() {
        guard let range = Range(match.range, in: out) else { continue }
        out.replaceSubrange(range, with: fingerprint(String(out[range]), salt: salt))
      }
    }
    return out
  }

  /// Stable per-identifier so log lines stay correlatable, and salted so it cannot
  /// be reversed: an unsalted hash of a phone number is a ~10^10 search space, i.e.
  /// seconds to brute force, which would make the redaction decorative.
  static func fingerprint(_ value: String, salt: Data) -> String {
    var hasher = SHA256()
    hasher.update(data: salt)
    hasher.update(data: Data(value.utf8))
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return "h:" + hex.prefix(12)
  }

  static func loadOrCreateSalt(at url: URL) -> Data {
    if let existing = try? Data(contentsOf: url), existing.count >= 16 {
      return existing
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      // Never fall back to a constant: a predictable salt is no salt. A
      // per-process random value still redacts, it just breaks correlation
      // across restarts, which is the right way to fail here.
      bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
    }
    let salt = Data(bytes)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? salt.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path
    )
    return salt
  }

  // MARK: - Rotation

  private func rotateIfNeeded() {
    let fm = FileManager.default
    guard
      let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
      let size = attrs[.size] as? Int,
      size > maxBytes
    else {
      return
    }
    // We own this file, so a rename actually rotates — which it would not have
    // when launchd held the descriptor (#174).
    let rotated = fileURL.appendingPathExtension("1")
    try? fm.removeItem(at: rotated)
    try? fm.moveItem(at: fileURL, to: rotated)
  }

  private func append(_ line: String) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: fileURL.path) {
      try? fm.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      fm.createFile(atPath: fileURL.path, contents: nil)
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      enforcedMode = true
    } else if !enforcedMode {
      // Setting the mode only on create left every EXISTING install world-readable:
      // launchd made this file 0644 long before the daemon owned it, and creating-
      // only meant we inherited that forever. Measured 0644 on a real upgrade.
      // Once per process is enough — we hold the file for the daemon's lifetime.
      let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
      let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue
      if mode != 0o600 {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      }
      enforcedMode = true
    }
    guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}

/// `~/Library/Logs/imessage-unsent/watcher.log` — the daemon's own structured log.
public func defaultDaemonLogURL(home: URL = imuUserHomeDirectory()) -> URL {
  home
    .appendingPathComponent("Library/Logs/imessage-unsent", isDirectory: true)
    .appendingPathComponent("watcher.log", isDirectory: false)
}
