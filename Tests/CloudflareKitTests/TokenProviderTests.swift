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
