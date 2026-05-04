import Contacts
import Foundation
import SwiftUI

/// Tracks the GUI app's Contacts authorization status and exposes actions to
/// request it. Mirrors `NotificationPermissionModel` for the notifications
/// flow but for Contacts (used to resolve display names + avatars from
/// phone numbers / emails).
@MainActor
public final class ContactsPermissionModel: ObservableObject {
  @Published public private(set) var status: CNAuthorizationStatus = .notDetermined
  @Published public private(set) var isRequesting: Bool = false
  @Published public private(set) var promptSuppressed: Bool = false
  @Published public private(set) var lastTestResult: TestResult?

  public enum TestResult: Equatable {
    case sample(name: String, source: String)
    case empty
    case failed(String)
  }

  private let store: CNContactStore

  public init(store: CNContactStore = CNContactStore()) {
    self.store = store
    refresh()
  }

  public func refresh() {
    status = CNContactStore.authorizationStatus(for: .contacts)
  }

  /// Requests Contacts access if `status == .notDetermined`. If macOS
  /// suppresses the prompt (because the user previously denied), records that
  /// fact so the UI can pivot to "Open System Settings".
  public func enable() async {
    isRequesting = true
    promptSuppressed = false
    let granted: Bool = await withCheckedContinuation { continuation in
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized:
        continuation.resume(returning: true)
      case .notDetermined:
        store.requestAccess(for: .contacts) { granted, _ in
          continuation.resume(returning: granted)
        }
      default:
        continuation.resume(returning: false)
      }
    }
    refresh()
    isRequesting = false
    promptSuppressed = (status == .notDetermined && !granted)
  }

  /// Sample lookup against the user's address book to confirm Contacts
  /// resolution is actually working — pulls the first contact and returns
  /// its display name. Used by the Settings "Test" button.
  public func sampleLookup() {
    guard status == .authorized else {
      lastTestResult = .failed("Contacts not authorized — click \"Open System Settings\" first.")
      return
    }
    do {
      let request = CNContactFetchRequest(keysToFetch: [
        CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey
      ] as [CNKeyDescriptor])
      var found: CNContact?
      try store.enumerateContacts(with: request) { contact, stop in
        found = contact
        stop.pointee = true
      }
      if let contact = found {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "(unnamed)"
        let phone = contact.phoneNumbers.first?.value.stringValue ?? "no phone"
        lastTestResult = .sample(name: name, source: phone)
      } else {
        lastTestResult = .empty
      }
    } catch {
      lastTestResult = .failed("Lookup failed: \(error.localizedDescription)")
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      lastTestResult = nil
    }
  }

  public var statusText: String {
    switch status {
    case .authorized: return "Authorized"
    case .denied: return "Denied"
    case .restricted: return "Restricted"
    case .notDetermined: return "Not yet requested"
    @unknown default: return "Unknown"
    }
  }

  public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
}
