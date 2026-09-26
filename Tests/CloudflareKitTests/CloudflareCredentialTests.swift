import Foundation
import Testing

@testable import CloudflareKit

/// The credential enum D1Explorer and R2Explorer each defined for themselves, now shared.
/// Its JSON is load-bearing: both apps have connections on disk in this exact shape, so the
/// fixtures below are copied from what their `ConnectionCredential` encodes today.
@Suite("Cloudflare credential")
@MainActor
struct CloudflareCredentialTests {

  @Test func pastedToken_decodesTheAppsStoredShape() throws {
    let stored = Data(#"{"pastedToken":{}}"#.utf8)
    #expect(try JSONDecoder().decode(CloudflareCredential.self, from: stored) == .pastedToken)
  }

  @Test func oauth_decodesTheAppsStoredShape() throws {
    let stored = Data(#"{"oauth":{"accountId":"abc123"}}"#.utf8)
    #expect(
      try JSONDecoder().decode(CloudflareCredential.self, from: stored)
        == .oauth(accountId: "abc123"))
  }

  @Test func bothCases_reencodeToTheSameShape() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(
      String(decoding: try encoder.encode(CloudflareCredential.pastedToken), as: UTF8.self)
        == #"{"pastedToken":{}}"#)
    #expect(
      String(
        decoding: try encoder.encode(CloudflareCredential.oauth(accountId: "abc123")),
        as: UTF8.self) == #"{"oauth":{"accountId":"abc123"}}"#)
  }

  @Test func pastedToken_resolvesToAFixedProvider() async throws {
    let provider = try CloudflareCredential.pastedToken.tokenProvider(
      pastedToken: { "secret" }, accounts: nil)
    #expect(try await provider.token() == "secret")
    #expect(provider.canRefresh == false)
  }

  @Test func pastedToken_rethrowsAMissingSecret() {
    #expect(throws: KeychainStore.KeychainError.self) {
      try CloudflareCredential.pastedToken.tokenProvider(
        pastedToken: { throw KeychainStore.KeychainError.notFound }, accounts: nil)
    }
  }

  @Test func oauth_withoutTheAccount_isSignedOut() {
    #expect(throws: CloudflareCredentialError.signedOut(accountID: "gone")) {
      try CloudflareCredential.oauth(accountId: "gone").tokenProvider(
        pastedToken: { "unused" }, accounts: nil)
    }
  }
}
