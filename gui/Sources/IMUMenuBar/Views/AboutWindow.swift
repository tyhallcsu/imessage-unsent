import AppKit
import SwiftUI

struct AboutWindow: View {
  static let repoURL = URL(string: "https://github.com/tyhallcsu/imessage-unsent")!

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "message.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 84, height: 84)
        .foregroundStyle(.tint)
        .padding(.top, 24)

      VStack(spacing: 4) {
        Text("imessage-unsent")
          .font(.title2)
          .fontWeight(.semibold)

        Text("Version \(versionString)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      VStack(spacing: 4) {
        Text("Created by sharmanhall")
          .font(.callout)
        Link(destination: AboutWindow.repoURL) {
          HStack(spacing: 4) {
            Image(systemName: "link")
            Text("github.com/tyhallcsu/imessage-unsent")
          }
          .font(.callout)
        }
      }

      Spacer(minLength: 0)
    }
    .frame(width: 320, height: 280)
    .padding()
  }

  private var versionString: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    if let short, let build, build != short {
      return "\(short) (\(build))"
    }
    return short ?? build ?? "unknown"
  }
}
