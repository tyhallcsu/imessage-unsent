import AppKit
import IMUMenuBarCore
import SwiftUI

struct AboutWindow: View {
  var body: some View {
    VStack(spacing: 0) {
      appIconView
        .padding(.top, 28)

      Text(AboutInfo.productName())
        .font(.title2.weight(.semibold))
        .padding(.top, 14)

      Text("Version \(AboutInfo.versionString())")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .textSelection(.enabled)
        .padding(.top, 2)

      Text(AboutInfo.tagline)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 12)
        .padding(.horizontal, 12)

      Divider()
        .padding(.horizontal, 40)
        .padding(.vertical, 14)

      VStack(spacing: 6) {
        Text("Created by \(AboutInfo.creator)")
          .font(.callout)
        Link(destination: AboutInfo.repoURL) {
          Label("github.com/tyhallcsu/imessage-unsent", systemImage: "link")
            .font(.callout)
        }
        .accessibilityLabel("Open the imessage-unsent repository on GitHub")
      }

      VStack(spacing: 4) {
        Label(AboutInfo.privacyLine, systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(AboutInfo.licenseLine)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.top, 14)
      .padding(.bottom, 20)
    }
    .frame(width: 300)
    .fixedSize()
  }

  /// The bundled AppIcon.icns; NSImage picks the right representation for
  /// the display scale so this stays crisp on Retina. Falls back to the
  /// AppKit-provided application icon when the resource is missing (bare
  /// `swift run` binaries) so the window never renders an empty region.
  private var appIconView: some View {
    Image(nsImage: AboutInfo.appIcon() ?? NSApp?.applicationIconImage ?? NSImage())
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: 96, height: 96)
      .accessibilityHidden(true)
  }
}
