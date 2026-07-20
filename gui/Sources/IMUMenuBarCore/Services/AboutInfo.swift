import AppKit
import Foundation

/// Product metadata + bundle-derived strings for the About window (#137).
/// Lives in IMUMenuBarCore so the formatting logic is unit-testable; the
/// runtime values all come from the packaged bundle.
public enum AboutInfo {
  /// Canonical repository URL.
  public static let repoURL = URL(string: "https://github.com/tyhallcsu/imessage-unsent")!

  /// Maintainer handle — matches the LICENSE copyright holder. Hard rule
  /// (AGENTS.md): the handle, never a legal name.
  public static let creator = "sharmanhall"

  /// One-line product description shown under the app name.
  public static let tagline = "Recovers iMessages the sender unsent — read-only, from SQLite WAL snapshots."

  /// Read-only posture, stated verbatim in the About window.
  public static let privacyLine = "Read-only by design. Never writes to the Messages database."

  /// Mirrors LICENSE (MIT, © 2026 sharmanhall).
  public static let licenseLine = "MIT License · © 2026 sharmanhall"

  /// User-facing product name; prefers the bundle's display name so About
  /// always matches what Finder/Dock show for the installed app.
  public static func productName(info: [String: Any]?) -> String {
    if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty {
      return display
    }
    if let name = info?["CFBundleName"] as? String, !name.isEmpty {
      return name
    }
    return "iMessage Unsent"
  }

  public static func productName(bundle: Bundle = .main) -> String {
    productName(info: bundle.infoDictionary)
  }

  /// "0.5.0 (7)" when build differs from the marketing version, otherwise
  /// just the version; "dev" when the bundle carries neither (bare
  /// `swift run` binaries have no Info.plist).
  public static func versionString(short: String?, build: String?) -> String {
    if let short, let build, build != short {
      return "\(short) (\(build))"
    }
    return short ?? build ?? "dev"
  }

  public static func versionString(bundle: Bundle = .main) -> String {
    let info = bundle.infoDictionary
    return versionString(
      short: info?["CFBundleShortVersionString"] as? String,
      build: info?["CFBundleVersion"] as? String
    )
  }

  /// The real app icon staged at Contents/Resources/AppIcon.icns by
  /// build-release.sh / build_and_run.sh. Returns nil when running
  /// unbundled so callers can degrade to `NSApp.applicationIconImage`
  /// instead of drawing placeholder artwork.
  public static func appIcon(bundle: Bundle = .main) -> NSImage? {
    bundle.image(forResource: "AppIcon")
  }
}
