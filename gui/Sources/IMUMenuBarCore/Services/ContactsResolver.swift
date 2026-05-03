import Contacts
import Foundation

/// Resolves an iMessage handle (phone number or email) to a contact display
/// name and avatar image. All calls are read-only; failures (permission denied,
/// no match, or non-phone handle) return `nil` so the UI degrades cleanly to
/// handle-only display.
public protocol ContactsResolving {
  func displayName(forHandle handle: String) -> String?
  func avatarImageData(forHandle handle: String) -> Data?
}

/// No-op implementation used in tests and as a default before the user grants
/// Contacts access.
public struct NoContactsResolver: ContactsResolving {
  public init() {}
  public func displayName(forHandle _: String) -> String? { nil }
  public func avatarImageData(forHandle _: String) -> Data? { nil }
}

/// Production implementation backed by `CNContactStore`. Caches lookups in
/// memory so repeated row renders don't re-query the store.
public final class CNContactsResolver: ContactsResolving {
  private let store = CNContactStore()
  private let lock = NSLock()
  private var nameCache: [String: String?] = [:]
  private var imageCache: [String: Data?] = [:]

  public init() {}

  /// Asks the user for Contacts access if not yet decided. Safe to call from
  /// any thread; `completion` is invoked with whether access is now granted.
  public func requestAccessIfNeeded(completion: @escaping (Bool) -> Void) {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    switch status {
    case .authorized:
      completion(true)
    case .notDetermined:
      store.requestAccess(for: .contacts) { granted, _ in
        completion(granted)
      }
    default:
      completion(false)
    }
  }

  public func displayName(forHandle handle: String) -> String? {
    if let cached = readCache(nameCache, key: handle) { return cached }
    let name = lookupContact(forHandle: handle).flatMap { contact -> String? in
      let formatted = CNContactFormatter.string(from: contact, style: .fullName)
      return formatted?.isEmpty == false ? formatted : nil
    }
    writeCache(\CNContactsResolver.nameCache, key: handle, value: name)
    return name
  }

  public func avatarImageData(forHandle handle: String) -> Data? {
    if let cached = readCache(imageCache, key: handle) { return cached }
    let image = lookupContact(forHandle: handle)?.imageData
    writeCache(\CNContactsResolver.imageCache, key: handle, value: image)
    return image
  }

  private func lookupContact(forHandle handle: String) -> CNContact? {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
    guard handle.first == "+" || handle.first == "0" || (handle.first?.isNumber == true) else {
      // Email handles and chat-room handles aren't resolvable via phone
      // predicate; skip rather than throwing.
      return nil
    }
    let phone = CNPhoneNumber(stringValue: handle)
    let predicate = CNContact.predicateForContacts(matching: phone)
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactNicknameKey as CNKeyDescriptor,
      CNContactImageDataKey as CNKeyDescriptor,
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
    ]
    let matches = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
    return matches.first
  }

  private func readCache<V>(_ cache: [String: V?], key: String) -> V?? {
    lock.lock()
    defer { lock.unlock() }
    return cache[key]
  }

  private func writeCache<V>(_ keyPath: ReferenceWritableKeyPath<CNContactsResolver, [String: V?]>, key: String, value: V?) {
    lock.lock()
    self[keyPath: keyPath][key] = value
    lock.unlock()
  }
}
