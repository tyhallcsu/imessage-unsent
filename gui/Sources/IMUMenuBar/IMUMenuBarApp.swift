import AppKit
import Contacts
import IMUMenuBarCore
import SwiftUI

@main
struct IMUMenuBarApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(model: model)
    } label: {
      StatusLabel(health: model.health)
    }
    .menuBarExtraStyle(.menu)

    WindowGroup("Recovery History", id: "history") {
      HistoryView(model: model)
        .frame(minWidth: 760, minHeight: 460)
    }

    Settings {
      SettingsView()
        .frame(width: 520, height: 520)
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var health: DaemonHealth = .down
  @Published var archives: [ArchiveSummary] = []
  @Published var selectedDetail: RecoveryDetail?
  @Published var errorMessage: String?

  private let client = DaemonClient()
  private var timer: Timer?

  init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh() {
    do {
      let status = try client.ping()
      health = status.watching ? .watching : .idle
      archives = try client.archives(page: 1, limit: 50).archives
      errorMessage = nil
    } catch {
      health = .down
      errorMessage = error.localizedDescription
    }
  }

  func loadDetail(id: String) {
    do {
      selectedDetail = try client.recovery(id: id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func deleteArchive(id: String) {
    do {
      try client.deleteArchive(id: id)
      refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct StatusLabel: View {
  var health: DaemonHealth

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(systemName: "bubble.left.and.bubble.right")
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
        .offset(x: 2, y: 2)
    }
    .help("imessage-unsent: \(health.displayText)")
  }

  private var color: Color {
    switch health {
    case .down: .red
    case .idle: .gray
    case .watching: .green
    case .busy: .blue
    }
  }
}

struct MenuContentView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Open History") {
      openWindow(id: "history")
    }
    Button("Open Settings") {
      NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    Divider()
    if model.archives.isEmpty {
      Text(model.health == .down ? "Daemon unavailable" : "No recoveries yet")
    } else {
      ForEach(model.archives.prefix(5)) { archive in
        Button(shortTitle(for: archive)) {
          model.loadDetail(id: archive.id)
          openWindow(id: "history")
        }
      }
    }
    Divider()
    Button("Refresh") {
      model.refresh()
    }
    Button("Quit") {
      NSApplication.shared.terminate(nil)
    }
  }

  private func shortTitle(for archive: ArchiveSummary) -> String {
    let base = archive.preview ?? archive.handle ?? archive.id
    if base.count <= 30 { return base }
    return String(base.prefix(27)) + "..."
  }
}

struct HistoryView: View {
  @ObservedObject var model: AppModel
  @State private var searchText = ""
  @State private var selection: ArchiveSummary.ID?
  private let contacts = ContactResolver()

  var filtered: [ArchiveSummary] {
    guard !searchText.isEmpty else { return model.archives }
    return model.archives.filter { archive in
      let name = contacts.displayName(for: archive.handle)
      return name.localizedCaseInsensitiveContains(searchText)
        || (archive.preview ?? "").localizedCaseInsensitiveContains(searchText)
        || (archive.handle ?? "").localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    NavigationSplitView {
      List(filtered, selection: $selection) { archive in
        VStack(alignment: .leading, spacing: 3) {
          Text(contacts.displayName(for: archive.handle))
            .lineLimit(1)
          Text(archive.preview ?? (archive.recovered ? "Recovered text" : "Not recoverable"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .tag(archive.id)
      }
      .searchable(text: $searchText)
      .toolbar {
        Button {
          model.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
      }
    } detail: {
      if let selected = filtered.first(where: { $0.id == selection }) {
        RecoveryDetailView(archive: selected, detail: model.selectedDetail, model: model)
          .onAppear { model.loadDetail(id: selected.id) }
          .onChange(of: selected.id) { newID in model.loadDetail(id: newID) }
      } else {
        VStack(spacing: 12) {
          Image(systemName: "bubble.left.and.bubble.right")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text("No retractions detected yet")
            .font(.title3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

struct RecoveryDetailView: View {
  var archive: ArchiveSummary
  var detail: RecoveryDetail?
  @ObservedObject var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(archive.preview ?? archive.id)
          .font(.title2)
          .lineLimit(3)
        Text(detail?.recoveredText ?? "Text was not recoverable from this WAL snapshot.")
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail?.recoveredText ?? "", forType: .string)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .disabled(detail?.recoveredText == nil)

          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: archive.archiveDir)])
          } label: {
            Label("Open Archive", systemImage: "folder")
          }

          Button(role: .destructive) {
            model.deleteArchive(id: archive.id)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          metadata("Handle", archive.handle)
          metadata("GUID", archive.guid)
          metadata("ROWID", archive.rowid.map(String.init))
          metadata("Source", detail?.recovered.source)
          metadata("WAL offset", detail?.recovered.walOffset.map(String.init))
        }
      }
      .padding()
    }
  }

  private func metadata(_ label: String, _ value: String?) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value ?? "-").textSelection(.enabled)
    }
  }
}

struct SettingsView: View {
  @State private var settings = AppSettings()
  @State private var message = ""
  private let configURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.config/imessage-unsent/config.toml")

  var body: some View {
    Form {
      Section("Watching") {
        Button("Restart Daemon") { restartDaemon() }
      }
      Section("Notifications") {
        Toggle("Show notifications", isOn: $settings.notificationsEnabled)
        Slider(value: Binding(get: {
          Double(settings.previewChars)
        }, set: {
          settings.previewChars = Int($0)
        }), in: 0...200, step: 10) {
          Text("Preview Length")
        }
        TextField("Webhook URL", text: $settings.webhookURL)
        SecureField("Webhook Secret", text: $settings.webhookSecret)
        Button("Test Webhook") {
          save()
          message = "Webhook settings saved."
        }
      }
      Section("Privacy") {
        Picker("Retention", selection: $settings.retentionLimit) {
          Text("Last 10").tag(10)
          Text("Last 100").tag(100)
          Text("All").tag(Int.max)
        }
        Toggle("Redact recovered text in notifications", isOn: Binding(get: {
          settings.previewChars == 0
        }, set: { redacted in
          settings.previewChars = redacted ? 0 : 80
        }))
      }
      Section("Filters") {
        TextField("Allow handles", text: Binding(get: {
          settings.allowList.joined(separator: ", ")
        }, set: {
          settings.allowList = splitHandles($0)
        }))
        TextField("Deny handles", text: Binding(get: {
          settings.denyList.joined(separator: ", ")
        }, set: {
          settings.denyList = splitHandles($0)
        }))
      }
      Section("Diagnostics") {
        Button("Open Log File") {
          NSWorkspace.shared.open(URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Logs/imessage-unsent/watcher.log"))
        }
        Button("Reveal Archive Dir") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/imessage-unsent/archives")])
        }
        Button("Run Self-Test") {
          runSelfTest()
        }
      }
      if !message.isEmpty {
        Text(message).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scenePadding()
    .onAppear(perform: load)
    .onDisappear(perform: save)
  }

  private func load() {
    let raw = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    settings = SettingsDocument(rawText: raw).parse()
  }

  private func save() {
    let raw = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    let updated = SettingsDocument(rawText: raw).updating(settings)
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    restartDaemon()
  }

  private func restartDaemon() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.imu.watcher"]
    try? process.run()
    message = "Daemon reload requested."
  }

  private func runSelfTest() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/imessage-unsent/bin/imu-watcher")
    process.arguments = ["--self-test"]
    try? process.run()
    message = "Self-test requested."
  }

  private func splitHandles(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}

final class ContactResolver {
  private let store = CNContactStore()

  func displayName(for handle: String?) -> String {
    guard let handle, !handle.isEmpty else { return "Unknown sender" }
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
    let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
    if let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first {
      let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { return name }
    }
    return handle
  }
}
