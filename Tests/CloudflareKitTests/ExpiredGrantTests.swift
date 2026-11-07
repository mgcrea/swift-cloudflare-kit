import Foundation
import Synchronization
import Testing

@testable import CloudflareKit

/// Stands in for Cloudflare when a grant has died: the token endpoint answers a refresh with
/// `invalid_grant`, and answers a code exchange (a new sign-in) with a fresh grant. The
/// accounts endpoint lists whatever `listed` holds.
final class ExpiredGrantURLProtocol: URLProtocol, @unchecked Sendable {

  static let listed = Mutex<[String]>([])

  static func session(listing ids: [String]) -> URLSession {
    listed.withLock { $0 = ids }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExpiredGrantURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let (status, body) = answer()
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private func answer() -> (Int, String) {
    if request.url?.path == "/client/v4/accounts" {
      let accounts = Self.listed.withLock { $0 }
        .map { #"{"id":"\#($0)","name":"Account \#($0)"}"# }
        .joined(separator: ",")
      return (200, #"{"success":true,"result":[\#(accounts)]}"#)
    }
    if Self.formBody(of: request).contains("grant_type=refresh_token") {
      return (400, #"{"error":"invalid_grant","error_description":"expired"}"#)
    }
    return (
      200,
      #"""
      {"access_token":"fresh-access","expires_in":3600,"refresh_token":"fresh-grant",\#
      "scope":"d1.read account-settings.read"}
      """#
    )
  }

  /// `URLProtocol` sees an upload body only as a stream.
  private static func formBody(of request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
  }
}

/// A sign-in whose grant Cloudflare no longer honours has to be visible as such, so the UI
/// can offer to sign in again instead of showing it as working.
@Suite("Expired grant", .serialized)
@MainActor
struct ExpiredGrantTests {

  final class FakeKeychain: @unchecked Sendable {
    let items = Mutex<[String: String]>([:])
  }

  private func makeStore(keychain: FakeKeychain, listing ids: [String]) -> CloudflareAccountStore {
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
      session: ExpiredGrantURLProtocol.session(listing: ids))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("accounts-\(UUID().uuidString).json")
    return CloudflareAccountStore(storageURL: url, dependencies: dependencies, loadsFromDisk: false)
  }

  /// Two accounts from one sign-in and one from another. The dead grant is the first one's.
  private func seed(_ store: CloudflareAccountStore, _ keychain: FakeKeychain) {
    store.accounts = [
      CloudflareAccount(id: "a1", name: "One"),
      CloudflareAccount(id: "a2", name: "Two"),
      CloudflareAccount(id: "b1", name: "Other"),
    ]
    keychain.items.withLock {
      $0 = ["test.oauth.a1": "grant-A", "test.oauth.a2": "grant-A", "test.oauth.b1": "grant-B"]
    }
  }

  /// Signs in through the injected-redirect path, answering with the state it was sent.
  private func signIn(_ store: CloudflareAccountStore) async throws -> [CloudflareAccount] {
    try await store.signIn(redirectURI: "https://example.com/oauth/callback") { url in
      let state =
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "state" }?.value ?? ""
      return URL(string: "https://example.com/oauth/callback?code=c&state=\(state)")!
    }
  }

  @Test func aRefusedRefreshMarksEveryAccountOfThatGrant() async throws {
    let keychain = FakeKeychain()
    let store = makeStore(keychain: keychain, listing: [])
    seed(store, keychain)
    #expect(store.expiredAccountIDs.isEmpty)

    await #expect(throws: CloudflareOAuthError.grantExpired) {
      try await store.accessToken(for: "a1")
    }

    #expect(store.expiredAccountIDs == ["a1", "a2"])
    #expect(store.needsSignIn("a2"))
    #expect(!store.needsSignIn("b1"))
  }

  @Test func signingInAgainClearsTheAccountsItCovers() async throws {
    let keychain = FakeKeychain()
    let store = makeStore(keychain: keychain, listing: ["a1", "a2"])
    seed(store, keychain)
    _ = try? await store.accessToken(for: "a1")
    #expect(store.expiredAccountIDs == ["a1", "a2"])

    let unlocked = try await signIn(store)

    #expect(unlocked.map(\.id) == ["a1", "a2"])
    #expect(store.expiredAccountIDs.isEmpty)
    #expect(keychain.items.withLock { $0["test.oauth.a1"] } == "fresh-grant")
    #expect(try await store.accessToken(for: "a2") == "fresh-access")
  }

  /// Signing in as a different Cloudflare user leaves the expired account expired: it was
  /// not part of the new grant, so nothing about it changed.
  @Test func aSignInThatMissesTheAccountLeavesItExpired() async throws {
    let keychain = FakeKeychain()
    let store = makeStore(keychain: keychain, listing: ["b1"])
    seed(store, keychain)
    _ = try? await store.accessToken(for: "a1")

    _ = try await signIn(store)

    #expect(store.expiredAccountIDs == ["a1", "a2"])
  }

  @Test func signingOutForgetsTheExpiredMark() async throws {
    let keychain = FakeKeychain()
    let store = makeStore(keychain: keychain, listing: [])
    seed(store, keychain)
    _ = try? await store.accessToken(for: "a1")

    try? await store.signOut(accountID: "a1")

    #expect(store.expiredAccountIDs.isEmpty)
  }

  @Test func isGrantExpiredRecognisesOnlyThatError() {
    #expect(CloudflareOAuthError.isGrantExpired(CloudflareOAuthError.grantExpired))
    #expect(!CloudflareOAuthError.isGrantExpired(CloudflareOAuthError.cancelled))
    #expect(!CloudflareOAuthError.isGrantExpired(URLError(.notConnectedToInternet)))
  }
}
