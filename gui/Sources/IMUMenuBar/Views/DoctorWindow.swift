import AppKit
import IMUMenuBarCore
import SwiftUI

struct DoctorWindow: View {
  @StateObject private var model: HealthCheckModel

  init() {
    let client = DaemonControlClient()
    let checker = DefaultHealthChecker(daemon: client)
    _model = StateObject(wrappedValue: HealthCheckModel(checker: checker))
  }

  init(model: HealthCheckModel) {
    _model = StateObject(wrappedValue: model)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 520, minHeight: 540)
    .task {
      await model.reload()
    }
    .toolbar {
      ToolbarItemGroup(placement: .confirmationAction) {
        Button {
          Task { await model.reload() }
        } label: {
          Label("Re-run", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isLoading)

        Button {
          copyDiagnostics()
        } label: {
          Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(model.checks.isEmpty)
      }
    }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("App Doctor")
        .font(.title2)
        .bold()
      Text(headerSubtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
  }

  private var headerSubtitle: String {
    if model.isLoading {
      return "Running checks…"
    }
    if let lastRun = model.lastRunAt {
      let formatter = DateFormatter()
      formatter.timeStyle = .medium
      formatter.dateStyle = .none
      let counts = severityCounts
      let pieces = [
        counts.fail > 0 ? "\(counts.fail) failing" : nil,
        counts.warn > 0 ? "\(counts.warn) warning" : nil,
        "\(counts.pass) passing"
      ].compactMap { $0 }
      return "Last run \(formatter.string(from: lastRun)) — \(pieces.joined(separator: ", "))"
    }
    return "Click Re-run to inspect the local install."
  }

  // MARK: Content

  private var content: some View {
    Group {
      if model.checks.isEmpty && model.isLoading {
        ProgressView("Inspecting daemon, paths, and permissions…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.checks.isEmpty {
        ContentUnavailable("No checks have run yet.")
      } else {
        List(model.checks) { check in
          HealthCheckRow(check: check)
        }
        .listStyle(.inset)
      }
    }
  }

  // MARK: Helpers

  private struct SeverityCounts {
    var fail = 0
    var warn = 0
    var pass = 0
    var info = 0
  }

  private var severityCounts: SeverityCounts {
    var counts = SeverityCounts()
    for check in model.checks {
      switch check.severity {
      case .fail: counts.fail += 1
      case .warn: counts.warn += 1
      case .pass: counts.pass += 1
      case .info: counts.info += 1
      }
    }
    return counts
  }

  private func copyDiagnostics() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(model.diagnosticsText(), forType: .string)
  }
}

private struct HealthCheckRow: View {
  let check: HealthCheck
  @State private var detailExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: severityIcon)
          .foregroundStyle(severityColor)
          .font(.title3)
          .accessibilityLabel(check.severity.rawValue)
        VStack(alignment: .leading, spacing: 2) {
          Text(check.title)
            .font(.headline)
          Text(check.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(check.severity.rawValue.uppercased())
          .font(.caption2)
          .bold()
          .foregroundStyle(severityColor)
      }

      if check.detail != nil || check.remediation != nil {
        DisclosureGroup(isExpanded: $detailExpanded) {
          VStack(alignment: .leading, spacing: 6) {
            if let detail = check.detail, !detail.isEmpty {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let remediation = check.remediation, !remediation.isEmpty {
              if let url = check.remediationURL {
                Button {
                  NSWorkspace.shared.open(url)
                } label: {
                  Label(remediation, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.link)
              } else {
                Text(remediation)
                  .font(.caption)
                  .textSelection(.enabled)
              }
            }
          }
          .padding(.top, 4)
        } label: {
          Text(detailExpanded ? "Hide details" : "Show details")
            .font(.caption)
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var severityIcon: String {
    switch check.severity {
    case .fail: return "xmark.octagon.fill"
    case .warn: return "exclamationmark.triangle.fill"
    case .pass: return "checkmark.circle.fill"
    case .info: return "info.circle"
    }
  }

  private var severityColor: Color {
    switch check.severity {
    case .fail: return .red
    case .warn: return .orange
    case .pass: return .green
    case .info: return .secondary
    }
  }
}

private struct ContentUnavailable: View {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "stethoscope")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(message)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
