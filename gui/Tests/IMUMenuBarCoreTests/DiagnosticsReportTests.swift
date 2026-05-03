import Foundation
import XCTest
@testable import IMUMenuBarCore

final class DiagnosticsReportTests: XCTestCase {
  func testReportContainsHeaderAndAllChecksInSeverityOrder() {
    let checks: [HealthCheck] = [
      HealthCheck(
        id: "daemon.binary",
        category: .daemon,
        order: 0,
        severity: .pass,
        title: "Daemon binary",
        summary: "Installed",
        detail: "/Users/test/Library/Application Support/imessage-unsent/bin/imu-watcher",
        remediation: nil,
        remediationURL: nil
      ),
      HealthCheck(
        id: "daemon.running",
        category: .daemon,
        order: 3,
        severity: .fail,
        title: "Daemon running",
        summary: "Control socket did not respond",
        detail: nil,
        remediation: "launchctl kickstart -k gui/$(id -u)/com.imu.watcher",
        remediationURL: nil
      ),
      HealthCheck(
        id: "notifications",
        category: .permissions,
        order: 1,
        severity: .warn,
        title: "Notifications",
        summary: "Permission has not been requested yet",
        detail: nil,
        remediation: nil,
        remediationURL: nil
      )
    ]
    let now = Date(timeIntervalSince1970: 1_788_000_000)  // fixed for stable snapshot

    let report = Diagnostics.report(
      checks: checks,
      appVersion: "0.4.2",
      daemonVersion: "0.4.1",
      daemonReachable: false,
      now: now
    )

    XCTAssertTrue(report.hasPrefix("imessage-unsent diagnostics — "),
                  "report must start with the diagnostics header, got: \(report)")
    XCTAssertTrue(report.contains("GUI version: 0.4.2"))
    XCTAssertTrue(report.contains("Daemon version: 0.4.1 (not reachable)"))

    // FAIL must come before WARN must come before PASS in the body.
    let failIdx = try! XCTUnwrap(report.range(of: "[FAIL] daemon.running"))
    let warnIdx = try! XCTUnwrap(report.range(of: "[WARN] notifications"))
    let passIdx = try! XCTUnwrap(report.range(of: "[PASS] daemon.binary"))
    XCTAssertLessThan(failIdx.lowerBound, warnIdx.lowerBound)
    XCTAssertLessThan(warnIdx.lowerBound, passIdx.lowerBound)

    // Remediation lines are surfaced.
    XCTAssertTrue(report.contains("Remediation: launchctl kickstart -k gui/$(id -u)/com.imu.watcher"))
  }

  func testReportEndsWithSingleNewline() {
    let report = Diagnostics.report(
      checks: [
        HealthCheck(
          id: "daemon.log",
          category: .logs,
          order: 0,
          severity: .info,
          title: "Daemon log",
          summary: "Not yet created",
          detail: nil,
          remediation: nil,
          remediationURL: nil
        )
      ],
      appVersion: "dev",
      daemonVersion: nil,
      daemonReachable: false,
      now: Date(timeIntervalSince1970: 0)
    )
    XCTAssertTrue(report.hasSuffix("\n"))
    XCTAssertFalse(report.hasSuffix("\n\n"), "should not have a trailing blank line")
  }

  func testReportOmitsDaemonVersionGracefullyWhenNil() {
    let report = Diagnostics.report(
      checks: [],
      appVersion: "0.4.2",
      daemonVersion: nil,
      daemonReachable: false,
      now: Date(timeIntervalSince1970: 0)
    )
    XCTAssertTrue(report.contains("Daemon version: not reachable"))
  }
}
