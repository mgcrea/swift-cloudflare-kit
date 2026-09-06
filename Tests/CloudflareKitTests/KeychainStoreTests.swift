import Foundation
import Testing

@testable import CloudflareKit

// `KeychainStore` opts into the data-protection keychain, which requires the calling
// process to carry a `keychain-access-groups` entitlement and an unlocked user keybag.
// A bare SwiftPM test bundle has neither, so the round-trip tests are gated on an actual
// probe rather than left to fail and be explained in a comment. -34018
// (errSecMissingEntitlement) and -25308 (errSecInteractionNotAllowed) are the environment
// saying no; they are not regressions.
//
// The pure tests below always run, and they are the ones that cover the behaviour the two
// apps disagreed about before this package existed.
struct KeychainStoreTests {

  private static let store = KeychainStore(service: "io.mgcrea.CloudflareKitTests")

  private static let keychainUsable: Bool = {
    let key = "probe-\(UUID().uuidString)"
    defer { store.delete(forKey: key) }
    do {
      try store.save("probe", forKey: key)
      return true
    } catch {
      return false
    }
  }()

  private func uniqueKey() -> String { "test-\(UUID().uuidString)" }

  // MARK: - Round trips (need a usable keychain)

  @Test(.enabled(if: keychainUsable))
  func saveAndRead() throws {
    let key = uniqueKey()
    defer { Self.store.delete(forKey: key) }
    try Self.store.save("my-secret-token", forKey: key)
    #expect(try Self.store.read(forKey: key) == "my-secret-token")
  }

  @Test(.enabled(if: keychainUsable))
  func saveOverwrites() throws {
    let key = uniqueKey()
    defer { Self.store.delete(forKey: key) }
    try Self.store.save("first", forKey: key)
    try Self.store.save("second", forKey: key)
    #expect(try Self.store.read(forKey: key) == "second")
  }

  @Test(.enabled(if: keychainUsable))
  func deleteRemovesValue() throws {
    let key = uniqueKey()
    try Self.store.save("to-delete", forKey: key)
    Self.store.delete(forKey: key)
    #expect(throws: KeychainStore.KeychainError.self) {
      try Self.store.read(forKey: key)
    }
  }

  @Test(.enabled(if: keychainUsable))
  func servicesAreIsolatedFromEachOther() throws {
    // The reason `service` is a property and not a constant: D1Explorer and R2Explorer
    // must not be able to read each other's credentials under the same account key.
    let key = uniqueKey()
    let d1 = KeychainStore(service: "io.mgcrea.CloudflareKitTests.d1")
    let r2 = KeychainStore(service: "io.mgcrea.CloudflareKitTests.r2")
    defer {
      d1.delete(forKey: key)
      r2.delete(forKey: key)
    }
    try d1.save("d1-token", forKey: key)
    #expect(throws: KeychainStore.KeychainError.self) { try r2.read(forKey: key) }
    #expect(try d1.read(forKey: key) == "d1-token")
  }

  @Test(.enabled(if: keychainUsable))
  func synchronizableIsStampedAtSaveTime() throws {
    let key = uniqueKey()
    defer { Self.store.delete(forKey: key) }
    try Self.store.save("v", forKey: key, synchronizable: false)
    #expect(Self.store.isSynchronizable(forKey: key) == false)
  }

  // MARK: - Pure

  @Test func readingAnAbsentKeyIsNotFound() {
    #expect(throws: KeychainStore.KeychainError.self) {
      try Self.store.read(forKey: "definitely-absent-\(UUID().uuidString)")
    }
  }

  @Test func isSynchronizableIsNilWhenThereIsNoItem() {
    #expect(Self.store.isSynchronizable(forKey: "absent-\(UUID().uuidString)") == nil)
  }

  @Test func deletingAnAbsentKeyIsSilent() {
    Self.store.delete(forKey: "absent-\(UUID().uuidString)")
  }

  @Test func errorsDescribeThemselvesDistinctly() {
    // `.notFound` and `.readFailed` must not read alike: one is fixed by pasting a
    // credential, the other by unlocking the keybag.
    #expect(
      KeychainStore.KeychainError.saveFailed(-25300).errorDescription
        == "Keychain save failed (OSStatus -25300)")
    #expect(KeychainStore.KeychainError.notFound.errorDescription == "Token not found in Keychain")
    #expect(
      KeychainStore.KeychainError.readFailed(-25308).errorDescription
        == "Keychain read failed (OSStatus -25308)")
    #expect(
      KeychainStore.KeychainError.malformed.errorDescription
        == "Keychain item is not readable text")
  }

  @Test func malformedIsItsOwnCase() {
    // The divergence this extraction settled: an item that exists but is not UTF-8 is
    // neither missing nor a read failure, and both apps used to claim one of those.
    //
    // Compared with `if case` rather than `==` on purpose — `KeychainError` must not be
    // Equatable, or `catch KeychainError.notFound` stops compiling in both apps.
    if case .notFound = KeychainStore.KeychainError.malformed {
      Issue.record("malformed must not match notFound")
    }
    if case .readFailed = KeychainStore.KeychainError.malformed {
      Issue.record("malformed must not match readFailed")
    }
    if case .malformed = KeychainStore.KeychainError.malformed {
    } else {
      Issue.record("malformed must match itself")
    }
  }

  @Test func absentKeyIsNotFoundSpecifically() {
    // Narrower than the `.self` throws check above: the *case* matters, because
    // ConnectionDoctor catches exactly this one to tell the user to paste a credential.
    do {
      _ = try Self.store.read(forKey: "absent-\(UUID().uuidString)")
      Issue.record("expected a throw")
    } catch KeychainStore.KeychainError.notFound {
      // expected
    } catch {
      Issue.record("expected .notFound, got \(error)")
    }
  }
}
