import Foundation
import Testing

@testable import CloudflareKit

/// The account store, exercised without a network or a Keychain: the Keychain is three
/// closures over a dictionary, and every test drives the parts that do not cross the wire.
@Suite("Cloudflare account store")
@MainActor
struct CloudflareAccountStoreTests {

  /// An in-memory stand-in for the app's Keychain helper.
  final class FakeKeychain: @unchecked Sendable {
    var items: [String: String] = [:]
    var synchronizableWrites: [String: Bool] = [:]
  }

  private func makeDependencies(
    keychain: FakeKeychain, synchronizable: Bool = false
  ) -> CloudflareAccountStore.Dependencies {
    CloudflareAccountStore.Dependencies(
      oauth: CloudflareOAuth(configuration: CloudflareOAuthTests.configuration),
      keychainKeyPrefix: "test.oauth.",
      readSecret: { key in
        guard let value = keychain.items[key] else {
          throw KeychainStore.KeychainError.notFound
        }
        return value
      },
      saveSecret: { value, key, sync in
        keychain.items[key] = value
        keychain.synchronizableWrites[key] = sync
      },
      deleteSecret: { key in keychain.items[key] = nil },
      isSynchronizable: { synchronizable })
  }

  private func makeStore(
    keychain: FakeKeychain = FakeKeychain(),
    synchronizable: Bool = false
  ) -> (CloudflareAccountStore, URL, CloudflareAccountStore.Dependencies) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("accounts-\(UUID().uuidString).json")
    let dependencies = makeDependencies(keychain: keychain, synchronizable: synchronizable)
    return (
      CloudflareAccountStore(storageURL: url, dependencies: dependencies), url,
      dependencies
    )
  }

  // MARK: - Keys

  /// The prefix must namespace grant tokens apart from an app's pasted per-connection
  /// tokens, so a connection id and an account id can never collide and a migration can
  /// tell the two kinds apart by key alone.
  @Test func account_keychainKeyIsPrefixed() {
    let account = CloudflareAccount(id: "abc", name: "Acme")

    #expect(account.keychainKey(prefix: "com.swiftd1.oauth.") == "com.swiftd1.oauth.abc")
  }

  /// A declined optional scope is a smaller grant, not an error. The comparison is against
  /// the app's own configuration, because the optional set differs per app.
  @Test func account_reportsDeclinedOptionalScopes() {
    let configuration = CloudflareOAuthTests.configuration
    let account = CloudflareAccount(
      id: "a", name: "n", grantedScopes: ["d1.read", "account-settings.read", "d1.write"])

    #expect(account.declinedScopes(against: configuration) == ["account-analytics.read"])
  }

  @Test func account_reportsNothingDeclinedWhenEverythingWasGranted() {
    let configuration = CloudflareOAuthTests.configuration
    let account = CloudflareAccount(id: "a", name: "n", grantedScopes: configuration.allScopes)

    #expect(account.declinedScopes(against: configuration).isEmpty)
  }

  // MARK: - Persistence

  /// Accounts live in their own file, and it holds no secret: the refresh token is in the
  /// Keychain and the access token is never persisted at all.
  @Test func store_roundTripsAccountsThroughDisk() throws {
    let (store, url, dependencies) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    store.accounts = [CloudflareAccount(id: "a1", name: "Acme", grantedScopes: ["d1.read"])]
    store.save()

    let written = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
    #expect(written.contains("a1"))
    #expect(!written.contains("token"))

    let reloaded = CloudflareAccountStore(
      storageURL: url, dependencies: dependencies)
    #expect(reloaded.accounts.map(\.id) == ["a1"])
  }

  /// Nothing here is irreplaceable — the refresh tokens are in the Keychain and the rest is
  /// re-derivable by signing in again — so a corrupt file starts empty rather than throwing
  /// on launch or preserving garbage.
  @Test func store_startsEmptyOnACorruptFile() throws {
    let (_, url, dependencies) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{ not json".utf8).write(to: url)

    let reloaded = CloudflareAccountStore(
      storageURL: url, dependencies: dependencies)
    #expect(reloaded.accounts.isEmpty)
  }

  @Test func store_hasNoAccountsBeforeAnyoneSignsIn() {
    let (store, url, _) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(store.accounts.isEmpty)
    #expect(store.account(id: "nope") == nil)
  }

  // MARK: - Grant sharing

  /// One authorization can unlock several Cloudflare accounts, and they share one refresh
  /// token. Signing out of one revokes that token, so the others must be forgotten too —
  /// otherwise they look signed in and fail on their next request with nothing to explain
  /// it.
  @Test func store_groupsAccountsThatShareARefreshToken() {
    let keychain = FakeKeychain()
    let (store, url, _) = makeStore(keychain: keychain)
    defer { try? FileManager.default.removeItem(at: url) }

    store.accounts = [
      CloudflareAccount(id: "a1", name: "One"),
      CloudflareAccount(id: "a2", name: "Two"),
      CloudflareAccount(id: "b1", name: "Other"),
    ]
    keychain.items["test.oauth.a1"] = "grant-A"
    keychain.items["test.oauth.a2"] = "grant-A"
    keychain.items["test.oauth.b1"] = "grant-B"

    #expect(Set(store.accountsSharingGrant(with: "a1")) == ["a1", "a2"])
    #expect(store.accountsSharingGrant(with: "b1") == ["b1"])
  }

  /// An account with no stored token still reports itself, so a sign-out on a
  /// half-provisioned account still clears it rather than returning nothing to forget.
  @Test func store_reportsItselfWhenNoTokenIsStored() {
    let (store, url, _) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }
    store.accounts = [CloudflareAccount(id: "a1", name: "One")]

    #expect(store.accountsSharingGrant(with: "a1") == ["a1"])
  }

  // MARK: - Token provider

  /// A long-lived client holds this and calls it per request, which is what stops an OAuth
  /// access token going stale in a window left open for an afternoon.
  @Test func store_tokenProviderFailsClosedForAnUnknownAccount() async {
    let (store, url, _) = makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: CloudflareOAuthError.grantExpired) {
      _ = try await store.tokenProvider(for: "missing").token()
    }
  }
}
