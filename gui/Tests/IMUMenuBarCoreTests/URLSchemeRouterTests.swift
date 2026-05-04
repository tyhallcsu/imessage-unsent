import Foundation
import XCTest
@testable import IMUMenuBarCore

final class URLSchemeRouterTests: XCTestCase {
  func testHistoryHostRoutesToHistory() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://history")!), .history)
  }

  func testHistoryHostWithTrailingSlashRoutesToHistory() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://history/")!), .history)
  }

  func testHistoryWithArchiveIdRoutesToHistoryEntry() {
    let id = "2026-05-04T191130Z-397888"
    XCTAssertEqual(
      routeIMUURL(URL(string: "imu://history/\(id)")!),
      .historyEntry(id)
    )
  }

  func testHistoryWithMalformedArchiveIdFallsBackToHistory() {
    // Path doesn't match the canonical YYYY-MM-DDTHHMMSSZ-rowid pattern.
    XCTAssertEqual(routeIMUURL(URL(string: "imu://history/not-a-real-archive-id")!), .history)
  }

  func testSettingsHostRoutesToSettings() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://settings")!), .settings)
  }

  func testDoctorHostRoutesToDoctor() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://doctor")!), .doctor)
  }

  func testAboutHostRoutesToAbout() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://about")!), .about)
  }

  func testArchiveHostRoutesToArchiveURL() {
    let route = routeIMUURL(URL(string: "imu://archive/private/tmp/foo/bar")!)
    XCTAssertEqual(route, .archive(URL(fileURLWithPath: "/private/tmp/foo/bar", isDirectory: true)))
  }

  func testArchiveWithoutPathIsUnknown() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://archive")!), .unknown)
  }

  func testNonImuSchemeIsUnknown() {
    XCTAssertEqual(routeIMUURL(URL(string: "https://history")!), .unknown)
  }

  func testUnknownHostIsUnknown() {
    XCTAssertEqual(routeIMUURL(URL(string: "imu://garbage")!), .unknown)
  }
}
