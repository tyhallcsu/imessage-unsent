import Foundation
import XCTest
@testable import IMUMenuBarCore

/// Parser-only tests for LaunchctlPrintParser. The fixtures are synthetic but
/// modelled after real `launchctl print gui/<uid>/com.imu.watcher` output:
/// the format is documented as stable for the keys we read.
final class LaunchctlProbeParserTests: XCTestCase {
  func testNotFound_fromStderr_evenWhenExitZero() {
    let result = LaunchctlPrintParser.parse(
      exitCode: 113,
      stdout: "",
      stderr: "Could not find service \"com.imu.watcher\" in domain for: gui/501\n"
    )
    XCTAssertEqual(result, .notFound)
  }

  func testNotFound_caseInsensitiveOnStderr() {
    let result = LaunchctlPrintParser.parse(
      exitCode: 3,
      stdout: "",
      stderr: "could not find service\n"
    )
    XCTAssertEqual(result, .notFound)
  }

  func testLoadedRunning_extractsStatePidAndExitCode() {
    let stdout = """
      com.imu.watcher = {
      \tactive count = 1
      \tpath = /Users/test/Library/LaunchAgents/com.imu.watcher.plist
      \ttype = LaunchAgent
      \tstate = running
      \tprogram = /Users/test/Library/Application Support/imessage-unsent/bin/imu-watcher
      \tpid = 8421
      \tlast exit code = 0
      }
      """
    let result = LaunchctlPrintParser.parse(exitCode: 0, stdout: stdout, stderr: "")
    XCTAssertEqual(result, .loaded(state: "running", pid: 8421, lastExitCode: 0))
  }

  func testLoadedNotRunning_withCrashExitCode() {
    let stdout = """
      com.imu.watcher = {
      \tstate = not running
      \tlast exit code = 1
      }
      """
    let result = LaunchctlPrintParser.parse(exitCode: 0, stdout: stdout, stderr: "")
    XCTAssertEqual(result, .loaded(state: "not running", pid: nil, lastExitCode: 1))
  }

  func testLoadedWaiting_withNoExitCode() {
    let stdout = """
      com.imu.watcher = {
      \tstate = waiting
      }
      """
    let result = LaunchctlPrintParser.parse(exitCode: 0, stdout: stdout, stderr: "")
    XCTAssertEqual(result, .loaded(state: "waiting", pid: nil, lastExitCode: nil))
  }

  func testErrorBranch_whenExitNonZeroAndStdoutEmpty_andNotFoundAbsent() {
    let result = LaunchctlPrintParser.parse(
      exitCode: 13,
      stdout: "",
      stderr: "Bootstrap failed: 5: Input/output error\n"
    )
    if case let .error(stderr, exitCode) = result {
      XCTAssertEqual(exitCode, 13)
      XCTAssertEqual(stderr, "Bootstrap failed: 5: Input/output error")
    } else {
      XCTFail("expected .error, got \(result)")
    }
  }

  func testLoadedUnknown_whenStdoutHasNoStateLineButExitZero() {
    // Some launchctl output omits a `state =` line entirely (e.g. when
    // throttled). We should still treat it as loaded so the UI can be honest.
    let stdout = """
      com.imu.watcher = {
      \tactive count = 0
      }
      """
    let result = LaunchctlPrintParser.parse(exitCode: 0, stdout: stdout, stderr: "")
    XCTAssertEqual(result, .loaded(state: "unknown", pid: nil, lastExitCode: nil))
  }

  func testKeyMatching_isWhitespaceTolerantAroundEquals() {
    let stdout = "state =     running\npid    =\t   42\n"
    let result = LaunchctlPrintParser.parse(exitCode: 0, stdout: stdout, stderr: "")
    XCTAssertEqual(result, .loaded(state: "running", pid: 42, lastExitCode: nil))
  }
}
