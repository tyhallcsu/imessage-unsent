import XCTest
@testable import IMUCore

/// Issue #179 — the GUI's `CNContactStore` path cannot be authorised on an
/// ad-hoc-signed build, so name resolution moves to the daemon, which has Full
/// Disk Access. These cover the matching rules and the read, against a synthetic
/// address book rather than the tester's real one.
final class AddressBookDirectoryTests: XCTestCase {
  private var dir: URL!

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("imu-ab-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    if let dir { try? FileManager.default.removeItem(at: dir) }
    dir = nil
  }

  // MARK: - Matching rules

  func testPhoneMatchingIgnoresFormattingAndCountryCode() {
    // chat.db stores "+17205550123"; the address book stores "(720) 555-0123".
    // Both must land on the same key or nothing ever resolves.
    let e164 = AddressBookDirectory.indexKey(for: "+17205550123")
    XCTAssertEqual(e164, AddressBookDirectory.indexKey(for: "(720) 555-0123"))
    XCTAssertEqual(e164, AddressBookDirectory.indexKey(for: "720-555-0123"))
    XCTAssertEqual(e164, AddressBookDirectory.indexKey(for: "7205550123"))
    XCTAssertEqual(e164, "p:7205550123")
  }

  func testDifferentNumbersDoNotCollide() {
    XCTAssertNotEqual(
      AddressBookDirectory.indexKey(for: "+17205550123"),
      AddressBookDirectory.indexKey(for: "+17205550124")
    )
  }

  func testEmailsMatchCaseInsensitively() {
    XCTAssertEqual(
      AddressBookDirectory.indexKey(for: "Someone@Example.COM"),
      AddressBookDirectory.indexKey(for: "someone@example.com")
    )
    XCTAssertEqual(AddressBookDirectory.indexKey(for: "a@b.com"), "e:a@b.com")
  }

  func testTooShortToBeAPhoneNumberIsRejected() {
    // Guard against a short string matching half the address book.
    XCTAssertNil(AddressBookDirectory.indexKey(for: "12345"))
    XCTAssertNil(AddressBookDirectory.indexKey(for: ""))
    XCTAssertNil(AddressBookDirectory.indexKey(for: "   "))
  }

  func testDisplayNameFallsBackToOrganization() {
    XCTAssertEqual(AddressBookDirectory.displayName(first: "Ada", last: "Lovelace", organization: nil), "Ada Lovelace")
    XCTAssertEqual(AddressBookDirectory.displayName(first: "Ada", last: nil, organization: nil), "Ada")
    XCTAssertEqual(AddressBookDirectory.displayName(first: nil, last: nil, organization: "Acme"), "Acme")
    XCTAssertNil(AddressBookDirectory.displayName(first: nil, last: nil, organization: nil))
    XCTAssertNil(AddressBookDirectory.displayName(first: "", last: "", organization: ""))
  }

  // MARK: - Reading

  func testResolvesFromASyntheticAddressBook() throws {
    try makeSource("src-1", rows: [("(720) 555-0123", "Ada", "Lovelace")])
    let book = AddressBookDirectory(sourcesDir: dir)

    XCTAssertEqual(book.displayName(forHandle: "+17205550123"), "Ada Lovelace")
    XCTAssertEqual(book.displayName(forHandle: "7205550123"), "Ada Lovelace")
    XCTAssertNil(book.displayName(forHandle: "+15559998888"))
  }

  func testMergesAcrossMultipleSources() throws {
    // A real Mac has several — this one had 6.
    try makeSource("src-1", rows: [("(720) 555-0123", "Ada", "Lovelace")])
    try makeSource("src-2", rows: [("(415) 555-0199", "Grace", "Hopper")])
    let book = AddressBookDirectory(sourcesDir: dir)

    XCTAssertEqual(book.displayName(forHandle: "+17205550123"), "Ada Lovelace")
    XCTAssertEqual(book.displayName(forHandle: "+14155550199"), "Grace Hopper")
    XCTAssertEqual(book.entryCount(), 2)
  }

  func testFirstSourceWinsOnDuplicates() throws {
    try makeSource("src-1", rows: [("(720) 555-0123", "Ada", "Lovelace")])
    try makeSource("src-2", rows: [("(720) 555-0123", "Someone", "Else")])
    let book = AddressBookDirectory(sourcesDir: dir)
    XCTAssertEqual(book.displayName(forHandle: "+17205550123"), "Ada Lovelace")
  }

  func testMissingOrUnreadableAddressBookDegradesToNil() {
    // No FDA, or no address book at all: raw handles, not a crash. This is the
    // pre-#179 behaviour and it must stay the failure mode.
    let absent = AddressBookDirectory(
      sourcesDir: dir.appendingPathComponent("does-not-exist", isDirectory: true)
    )
    XCTAssertNil(absent.displayName(forHandle: "+17205550123"))
    XCTAssertEqual(absent.entryCount(), 0)
  }

  func testGarbageDatabaseIsSkippedNotFatal() throws {
    let source = dir.appendingPathComponent("src-bad", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("not a database".utf8).write(
      to: source.appendingPathComponent("AddressBook-v22.abcddb")
    )
    try makeSource("src-good", rows: [("(720) 555-0123", "Ada", "Lovelace")])

    let book = AddressBookDirectory(sourcesDir: dir)
    XCTAssertEqual(book.displayName(forHandle: "+17205550123"), "Ada Lovelace")
  }

  // MARK: - Helper

  private func makeSource(
    _ name: String, rows: [(String, String, String)]
  ) throws {
    let source = dir.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let db = source.appendingPathComponent("AddressBook-v22.abcddb", isDirectory: false)

    var sql = """
    CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZORGANIZATION TEXT);
    CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
    CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS TEXT);
    """
    for (i, row) in rows.enumerated() {
      let pk = i + 1
      sql += "INSERT INTO ZABCDRECORD VALUES (\(pk), '\(row.1)', '\(row.2)', NULL);"
      sql += "INSERT INTO ZABCDPHONENUMBER VALUES (\(pk), \(pk), '\(row.0)');"
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [db.path, sql]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
