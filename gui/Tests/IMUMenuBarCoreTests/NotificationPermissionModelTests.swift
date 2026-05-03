import Foundation
import UserNotifications
import XCTest
@testable import IMUMenuBarCore

@MainActor
final class NotificationPermissionModelTests: XCTestCase {
  func testRefreshPopulatesStatusFromProbe() async {
    let probe = StubProbe(initialStatus: .authorized)
    let model = NotificationPermissionModel(probe: probe)

    await model.refresh()

    XCTAssertEqual(model.status, .authorized)
  }

  func testEnableRequestsAuthorizationAndRefreshes() async {
    let probe = StubProbe(initialStatus: .notDetermined, statusAfterRequest: .authorized)
    let model = NotificationPermissionModel(probe: probe)

    await model.enable()

    XCTAssertEqual(probe.requestCallCount, 1)
    XCTAssertEqual(probe.lastRequestedOptions, [.alert, .sound])
    XCTAssertEqual(model.status, .authorized)
  }

  func testStatusTextMapping() async {
    let probe = StubProbe(initialStatus: .denied)
    let model = NotificationPermissionModel(probe: probe)
    await model.refresh()
    XCTAssertEqual(model.statusText, "Denied")

    probe.currentStatus = .notDetermined
    await model.refresh()
    XCTAssertEqual(model.statusText, "Not yet requested")

    probe.currentStatus = .provisional
    await model.refresh()
    XCTAssertEqual(model.statusText, "Provisional")
  }

  func testEnableWhenDeniedDoesNotChangeStatus() async {
    let probe = StubProbe(initialStatus: .denied, requestGranted: false, statusAfterRequest: .denied)
    let model = NotificationPermissionModel(probe: probe)
    await model.refresh()

    await model.enable()

    XCTAssertEqual(probe.requestCallCount, 1)
    XCTAssertEqual(model.status, .denied)
  }
}

private final class StubProbe: NotificationPermissionProbing {
  var currentStatus: UNAuthorizationStatus
  var statusAfterRequest: UNAuthorizationStatus?
  var requestGranted: Bool
  private(set) var requestCallCount = 0
  private(set) var lastRequestedOptions: UNAuthorizationOptions?

  init(
    initialStatus: UNAuthorizationStatus,
    requestGranted: Bool = true,
    statusAfterRequest: UNAuthorizationStatus? = nil
  ) {
    self.currentStatus = initialStatus
    self.requestGranted = requestGranted
    self.statusAfterRequest = statusAfterRequest
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    currentStatus
  }

  func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
    requestCallCount += 1
    lastRequestedOptions = options
    if let next = statusAfterRequest {
      currentStatus = next
    }
    return requestGranted
  }
}
