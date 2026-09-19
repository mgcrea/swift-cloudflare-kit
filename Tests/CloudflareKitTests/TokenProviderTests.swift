import Foundation
import Testing

@testable import CloudflareKit

struct TokenProviderTests {

  @Test func fixedReturnsItsValue() async throws {
    let provider = TokenProvider.fixed("cf-token")
    #expect(try await provider.token() == "cf-token")
  }

  @Test func renewingResolvesEachTime() async throws {
    // The whole reason this type exists: a client holds the provider for an afternoon and
    // must see a refreshed token, not the one captured at init.
    let counter = Counter()
    let provider = TokenProvider.renewing { await counter.next() }
    #expect(try await provider.token() == "token-1")
    #expect(try await provider.token() == "token-2")
  }

  @Test func renewingPropagatesFailure() async throws {
    struct RefreshFailed: Error {}
    let provider = TokenProvider.renewing { throw RefreshFailed() }
    await #expect(throws: RefreshFailed.self) { try await provider.token() }
  }

  private actor Counter {
    private var n = 0
    func next() -> String {
      n += 1
      return "token-\(n)"
    }
  }
}

/// A token Cloudflare refused has to be dropped, or a client keeps sending it until the expiry
/// it was issued with — which is what Almanac did for hours, twice, with a relaunch as the only
/// way out.
struct RefusedTokenTests {

  private actor Recorder {
    private(set) var refused: [String] = []
    func record(_ token: String) { refused.append(token) }
  }

  @Test func refreshable_passesTheRefusedTokenToItsInvalidator() async throws {
    let recorder = Recorder()
    let provider = TokenProvider.refreshable(
      resolve: { "token-1" }, invalidate: { token, _ in await recorder.record(token) })

    await provider.invalidate("token-1", reason: "HTTP 401")

    #expect(await recorder.refused == ["token-1"])
    #expect(provider.canRefresh)
  }

  /// A pasted token has nothing behind it to refresh from, so retrying would send the same
  /// refused string again.
  @Test func fixedAndRenewing_cannotRefresh() {
    #expect(!TokenProvider.fixed("a").canRefresh)
    #expect(!TokenProvider.renewing { "a" }.canRefresh)
  }

  private func response(_ token: String, expiresIn: Int = 3600) -> CloudflareOAuth.TokenResponse {
    CloudflareOAuth.TokenResponse(
      accessToken: token, expiresIn: expiresIn, refreshToken: nil, scope: nil)
  }

  @Test func tokenStore_dropsTheRefusedTokenAndReportsTheLifetimeItHadLeft() async throws {
    let store = TokenStore()
    await store.adopt(response("a"), for: "acct")

    let remaining = await store.forget("acct", ifToken: "a")

    #expect(await store.cachedToken(for: "acct") == nil)
    #expect(try #require(remaining) > 3500)
  }

  /// Another request may have minted a new token between the refusal and this call. Dropping
  /// that one would throw away a good token to punish a bad one.
  @Test func tokenStore_keepsATokenThatIsNotTheRefusedOne() async {
    let store = TokenStore()
    await store.adopt(response("b"), for: "acct")

    let remaining = await store.forget("acct", ifToken: "a")

    #expect(await store.cachedToken(for: "acct") == "b")
    #expect(remaining == nil)
  }
}
