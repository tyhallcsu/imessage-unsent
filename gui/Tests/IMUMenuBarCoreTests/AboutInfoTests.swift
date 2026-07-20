import XCTest

@testable import IMUMenuBarCore

final class AboutInfoTests: XCTestCase {
  // MARK: versionString

  func testVersionStringAppendsBuildWhenItDiffers() {
    XCTAssertEqual(AboutInfo.versionString(short: "0.5.0", build: "7"), "0.5.0 (7)")
  }

  func testVersionStringCollapsesIdenticalShortAndBuild() {
    XCTAssertEqual(AboutInfo.versionString(short: "0.5.0", build: "0.5.0"), "0.5.0")
  }

  func testVersionStringFallsBackToBuildAlone() {
    XCTAssertEqual(AboutInfo.versionString(short: nil, build: "42"), "42")
  }

  func testVersionStringFallsBackToDevWhenBundleCarriesNeither() {
    XCTAssertEqual(AboutInfo.versionString(short: nil, build: nil), "dev")
  }

  // MARK: productName

  func testProductNamePrefersDisplayName() {
    let info: [String: Any] = [
      "CFBundleDisplayName": "iMessage Unsent",
      "CFBundleName": "IMUMenuBar"
    ]
    XCTAssertEqual(AboutInfo.productName(info: info), "iMessage Unsent")
  }

  func testProductNameFallsBackToBundleName() {
    XCTAssertEqual(AboutInfo.productName(info: ["CFBundleName": "IMUMenuBar"]), "IMUMenuBar")
  }

  func testProductNameIgnoresEmptyStringsAndFallsBackToConstant() {
    XCTAssertEqual(
      AboutInfo.productName(info: ["CFBundleDisplayName": "", "CFBundleName": ""]),
      "iMessage Unsent"
    )
    XCTAssertEqual(AboutInfo.productName(info: nil), "iMessage Unsent")
  }

  // MARK: fixed metadata

  func testRepoURLPointsAtTheCanonicalRepository() {
    XCTAssertEqual(AboutInfo.repoURL.absoluteString, "https://github.com/tyhallcsu/imessage-unsent")
  }

  func testCreatorIsTheMaintainerHandle() {
    // AGENTS.md hard rule: handle only, never a legal name.
    XCTAssertEqual(AboutInfo.creator, "sharmanhall")
  }

  // MARK: appIcon

  func testAppIconReturnsNilWhenBundleLacksTheResource() {
    // The unit-test bundle ships no AppIcon.icns — this pins the graceful
    // degradation contract the About view relies on. Presence in the real
    // .app is gated by rc_smoke.sh + tests/bats/91-app-icon.bats.
    XCTAssertNil(AboutInfo.appIcon(bundle: Bundle(for: AboutInfoTests.self)))
  }
}
