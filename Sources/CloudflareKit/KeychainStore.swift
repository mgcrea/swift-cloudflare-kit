import Foundation
import Security

/// Generic-password storage for one app's Cloudflare credentials.
///
/// Instances are values, not a shared singleton, because the `service` string namespaces
/// every item and each app owns its own: D1Explorer writes under `com.swiftd1`, R2Explorer
/// under `com.swiftr2`. Two apps sharing one service string would read each other's tokens,
/// so the namespace is a constructor argument rather than a constant.
public struct KeychainStore: Sendable {
  /// The `kSecAttrService` every item is filed under. One per app.
  public let service: String

  public init(service: String) {
    self.service = service
  }

  /// Writes `value`, replacing any existing item for `key`.
  ///
  /// `synchronizable` is read from the Settings toggle *at the time of the save*, so
  /// flipping the toggle does not retroactively move credentials already stored. See
  /// ``isSynchronizable(forKey:)``.
  public func save(_ value: String, forKey key: String, synchronizable: Bool = false) throws {
    let data = Data(value.utf8)
    delete(forKey: key)

    var addQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: key,
      kSecAttrService: service,
      kSecUseDataProtectionKeychain: true,
      kSecValueData: data,
    ]
    if synchronizable {
      addQuery[kSecAttrSynchronizable] = true
    }

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw KeychainError.saveFailed(status)
    }
  }

  /// Reads the stored string for `key`.
  ///
  /// Three outcomes, deliberately distinct. "No item saved", "the Keychain refused to
  /// answer" and "the item is there but unreadable" need different advice — paste a
  /// credential, unlock the keybag, re-authenticate — so collapsing any of them into
  /// `.notFound` would send the user to the wrong fix.
  ///
  /// The two apps disagreed here before this was extracted: one reported an undecodable
  /// payload as `.notFound`, which claims an item that exists does not; the other reported
  /// it as `.readFailed(errSecSuccess)`, which renders as "Keychain read failed (OSStatus
  /// 0)". Neither is true, hence ``KeychainError/malformed``.
  public func read(forKey key: String) throws -> String {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: key,
      kSecAttrService: service,
      kSecUseDataProtectionKeychain: true,
      kSecAttrSynchronizable: kSecAttrSynchronizableAny,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status != errSecItemNotFound else { throw KeychainError.notFound }
    guard status == errSecSuccess else { throw KeychainError.readFailed(status) }
    guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
      throw KeychainError.malformed
    }
    return string
  }

  /// Whether the stored item is flagged for iCloud Keychain sync, or `nil` when there is no
  /// item to ask about.
  ///
  /// Because ``save(_:forKey:synchronizable:)`` stamps the flag at save time, the stored
  /// attribute is the only truthful answer to "is this particular token syncing?" — which is
  /// why the connection doctors read it back rather than reporting the preference.
  public func isSynchronizable(forKey key: String) -> Bool? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: key,
      kSecAttrService: service,
      kSecUseDataProtectionKeychain: true,
      kSecAttrSynchronizable: kSecAttrSynchronizableAny,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let attrs = result as? [CFString: Any]
    else { return nil }
    return (attrs[kSecAttrSynchronizable] as? Bool) ?? false
  }

  /// Removes the item for `key`. Silent when there is nothing to remove.
  public func delete(forKey key: String) {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccount: key,
      kSecAttrService: service,
      kSecUseDataProtectionKeychain: true,
      kSecAttrSynchronizable: kSecAttrSynchronizableAny,
    ]
    SecItemDelete(query as CFDictionary)
  }

  /// Deliberately **not** `Equatable`.
  ///
  /// Adding that conformance changes how Swift resolves `~=` for a `catch` pattern, and
  /// every `catch KeychainError.notFound` in both apps stops compiling with "referencing
  /// operator function '~=' on '_ErrorCodeProtocol' requires that
  /// 'KeychainStore.KeychainError' conform to '_ErrorCodeProtocol'". The tests compare
  /// cases with `if case` instead; that is cheaper than churning every call site.
  public enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    /// Nothing is stored under this key.
    case notFound
    /// The item may well exist — the Keychain declined to say. Usually a locked keybag,
    /// which is a different problem from a missing token and has a different fix.
    case readFailed(OSStatus)
    /// The item exists and was returned, but its bytes are not UTF-8.
    case malformed

    public var errorDescription: String? {
      switch self {
      case .saveFailed(let status): return "Keychain save failed (OSStatus \(status))"
      case .notFound: return "Token not found in Keychain"
      case .readFailed(let status): return "Keychain read failed (OSStatus \(status))"
      case .malformed: return "Keychain item is not readable text"
      }
    }
  }
}
