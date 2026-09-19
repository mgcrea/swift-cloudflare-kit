import Foundation
import Testing

@testable import CloudflareKit

/// Answers requests from a script, in order, and records the bearer token each one carried.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {

  nonisolated(unsafe) static var statuses: [Int] = []
  nonisolated(unsafe) static var seenTokens: [String] = []

  static func session(answering statuses: [Int]) -> URLSession {
    Self.statuses = statuses
    Self.seenTokens = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
    Self.seenTokens.append(String(bearer.dropFirst("Bearer ".count)))
    let status = Self.statuses.isEmpty ? 500 : Self.statuses.removeFirst()
    let body =
      status == 200
      ? #"{"data":{"viewer":{"accounts":[]}},"errors":null}"#
      : #"{"errors":[{"code":10000,"message":"Authentication error"}]}"#
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// One retry, with a fresh token, after Cloudflare refuses the one it was sent — and only for
/// a credential that can actually produce a different token.
@Suite("Refused token retry", .serialized)
struct RefusedTokenRetryTests {

  private typealias Payload = CloudflareGraphQL.AccountsPayload<[String: Int]>

  private actor Minter {
    private var n = 0
    private(set) var refused: [String] = []
    func next() -> String {
      n += 1
      return "token-\(n)"
    }
    func refuse(_ token: String) { refused.append(token) }
  }

  private func refreshable(_ minter: Minter) -> TokenProvider {
    .refreshable(
      resolve: { await minter.next() }, invalidate: { token, _ in await minter.refuse(token) })
  }

  @Test func execute_retriesOnceWithAFreshTokenAfterA401() async throws {
    let minter = Minter()
    let session = ScriptedURLProtocol.session(answering: [401, 200])

    let payload: Payload? = try await CloudflareGraphQL.execute(
      query: "{}", token: refreshable(minter), session: session)

    #expect(payload != nil)
    #expect(ScriptedURLProtocol.seenTokens == ["token-1", "token-2"])
    #expect(await minter.refused == ["token-1"])
  }

  /// A second refusal from a token minted a moment ago is a real permission problem, and it
  /// must reach the user as one rather than loop.
  @Test func execute_givesUpAfterOneRetry() async throws {
    let minter = Minter()
    let session = ScriptedURLProtocol.session(answering: [403, 403])

    await #expect(throws: CloudflareGraphQLError.self) {
      let _: Payload? = try await CloudflareGraphQL.execute(
        query: "{}", token: refreshable(minter), session: session)
    }
    #expect(ScriptedURLProtocol.seenTokens == ["token-1", "token-2"])
  }

  @Test func execute_neverRetriesAPastedToken() async throws {
    let session = ScriptedURLProtocol.session(answering: [401, 200])

    await #expect(throws: CloudflareGraphQLError.self) {
      let _: Payload? = try await CloudflareGraphQL.execute(
        query: "{}", token: .fixed("pasted"), session: session)
    }
    #expect(ScriptedURLProtocol.seenTokens == ["pasted"])
  }
}
