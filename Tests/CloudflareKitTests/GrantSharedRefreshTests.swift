import Foundation
import Synchronization
import Testing

@testable import CloudflareKit

/// Stands in for Cloudflare's token endpoint: counts refreshes, takes a moment to answer so
/// concurrent callers overlap, and rotates the refresh token every time.
final class TokenEndpointURLProtocol: URLProtocol, @unchecked Sendable {

  static let refreshes = Mutex(0)

  static func session() -> URLSession {
    refreshes.withLock { $0 = 0 }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TokenEndpointURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let n = Self.refreshes.withLock { count in
      count += 1
      return count
    }
    let body = #"""
      {"access_token":"access-\#(n)","expires_in":3600,"refresh_token":"rotated-\#(n)",\#
      "scope":"d1.read account-settings.read"}
      """#
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

/// The accounts one sign-in unlocked share its refresh token, so they must share its
/// refreshes too: one at a time per grant, one token for all of them.
@Suite("Grant-shared refresh", .serialized)
@MainActor
struct GrantSharedRefreshTests {

  final class FakeKeychain: @unchecked Sendable {
    let items = Mutex<[String: String]>([:])
  }

  private func makeStore(keychain: FakeKeychain) -> CloudflareAccountStore {
    let dependencies = CloudflareAccountStore.Dependencies(
      oauth: CloudflareOAuth(configuration: CloudflareOAuthTests.configuration),
      keychainKeyPrefix: "test.oauth.",
      readSecret: { key in
        guard let value = keychain.items.withLock({ $0[key] }) else {
          throw KeychainStore.KeychainError.notFound
        }
        return value
      },
      saveSecret: { value, key, _ in keychain.items.withLock { $0[key] = value } },
      deleteSecret: { key in _ = keychain.items.withLock { $0.removeValue(forKey: key) } },
      isSynchronizable: { false },
      session: TokenEndpointURLProtocol.session())
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("accounts-\(UUID().uuidString).json")
    return CloudflareAccountStore(storageURL: url, dependencies: dependencies, loadsFromDisk: false)
  }

  /// A launch that loads every account at once: one refresh, one token, and the rotated
  /// refresh token saved for all three, not only the account that happened to refresh.
  @Test func accountsOfOneGrantRefreshOnceAndShareTheToken() async throws {
    let keychain = FakeKeychain()
    let store = makeStore(keychain: keychain)
    store.accounts = [
      CloudflareAccount(id: "a1", name: "One"),
      CloudflareAccount(id: "a2", name: "Two"),
      CloudflareAccount(id: "a3", name: "Three"),
    ]
    keychain.items.withLock {
      $0 = ["test.oauth.a1": "grant-A", "test.oauth.a2": "grant-A", "test.oauth.a3": "grant-A"]
    }

    async let one = store.accessToken(for: "a1")
    async let two = store.accessToken(for: "a2")
    async let three = store.accessToken(for: "a3")
    let tokens = try await [one, two, three]

    #expect(TokenEndpointURLProtocol.refreshes.withLock { $0 } == 1)
    #expect(Set(tokens) == ["access-1"])
    #expect(
      keychain.items.withLock { $0 }
        == [
          "test.oauth.a1": "rotated-1", "test.oauth.a2": "rotated-1", "test.oauth.a3": "rotated-1",
        ])
    #expect(store.accountsSharingGrant(with: "a3").sorted() == ["a1", "a2", "a3"])
  }

  /// Two separate sign-ins stay separate: each refreshes its own grant.
  @Test func separateGrantsRefreshSeparately() async throws {
    let keychain = FakeKeychain()
    let store = makeStore(keychain: keychain)
    store.accounts = [
      CloudflareAccount(id: "a1", name: "One"),
      CloudflareAccount(id: "b1", name: "Other"),
    ]
    keychain.items.withLock { $0 = ["test.oauth.a1": "grant-A", "test.oauth.b1": "grant-B"] }

    async let one = store.accessToken(for: "a1")
    async let other = store.accessToken(for: "b1")
    let tokens = try await [one, other]

    #expect(TokenEndpointURLProtocol.refreshes.withLock { $0 } == 2)
    #expect(Set(tokens).count == 2)
    #expect(
      keychain.items.withLock { $0["test.oauth.a1"] }
        != keychain.items.withLock { $0["test.oauth.b1"] })
  }

  /// A refused token is dropped for every account caching it, not only the one that was
  /// told: the others hold the same string and would only find out by sending it.
  @Test func aRefusedSharedTokenIsDroppedForEveryAccount() async throws {
    let tokens = TokenStore()
    _ = try await tokens.token(for: "a1", grant: "g", sharedWith: ["a1", "a2"]) {
      CloudflareOAuth.TokenResponse(
        accessToken: "shared", expiresIn: 3600, refreshToken: nil, scope: nil)
    }
    #expect(await tokens.cachedToken(for: "a2") == "shared")

    #expect(await tokens.forget("a1", ifToken: "shared") != nil)
    #expect(await tokens.cachedToken(for: "a1") == nil)
    #expect(await tokens.cachedToken(for: "a2") == nil)
  }
}
