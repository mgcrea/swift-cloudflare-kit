import Foundation

/// How a client obtains the bearer token for each request.
///
/// The clients used to capture `apiToken: String` at `init`, which was correct for exactly
/// as long as every credential was a permanent pasted API token. An OAuth access token
/// expires in minutes, so a client built once and held by a window for an afternoon would
/// have gone stale — and the failure surfaced as `.unauthorized`, telling the user their
/// token was revoked when it had merely aged.
///
/// Reading through a provider per request keeps that fix out of the call sites: a client
/// does not know or care which kind it holds, and the store's `makeService(for:)` factories
/// stay **synchronous**, because building a `.renewing` case captures a closure rather than
/// awaiting anything. That matters more than it looks: the factories are called from SwiftUI
/// `body` and `.task`, and an `async` factory would push `await` into every view.
public enum TokenProvider: Sendable {
  /// A pasted API token. Never changes, never fails.
  case fixed(String)
  /// An OAuth access token, refreshed on demand by the account store.
  case renewing(@Sendable () async throws -> String)
  /// An OAuth access token that can also be told Cloudflare refused it.
  ///
  /// `.renewing` refreshes only when the token's own expiry says so. Cloudflare can refuse a
  /// token well before that — measured in Almanac, twice, after hours of uptime — and a
  /// provider that cannot hear about it keeps handing out the refused token until the expiry
  /// it was issued with. A relaunch was the only way out, because it empties the cache.
  /// `invalidate` receives the refused token and why, so the cache can drop exactly that one.
  case refreshable(
    resolve: @Sendable () async throws -> String,
    invalidate: @Sendable (_ token: String, _ reason: String) async -> Void)

  public func token() async throws -> String {
    switch self {
    case .fixed(let value):
      return value
    case .renewing(let resolve), .refreshable(let resolve, _):
      return try await resolve()
    }
  }

  /// Whether asking again after a refusal can produce a different token.
  ///
  /// False for a pasted token, which has nothing behind it to refresh from: retrying would
  /// send the same refused string a second time.
  public var canRefresh: Bool {
    if case .refreshable = self { true } else { false }
  }

  /// Tells the provider Cloudflare refused `token`. A no-op for the kinds that cannot refresh.
  public func invalidate(_ token: String, reason: String) async {
    if case .refreshable(_, let invalidate) = self {
      await invalidate(token, reason)
    }
  }

  /// Sends a request with this provider's token, and once more with a fresh one if Cloudflare
  /// refuses it with a 401 or 403.
  ///
  /// **Once.** A second refusal from a token minted a moment ago is a real permission problem
  /// and comes back to the caller as the response it is, to be reported as one. A provider
  /// that cannot refresh is never retried: it would send the same refused string again.
  ///
  /// `makeRequest` receives the bearer token rather than a finished request, so the retry
  /// carries the new token and nothing else changes.
  public func data(
    for makeRequest: (_ bearer: String) throws -> URLRequest, session: URLSession
  ) async throws -> (Data, URLResponse) {
    let first = try await token()
    let (data, response) = try await session.data(for: try makeRequest(first))
    guard canRefresh, let http = response as? HTTPURLResponse,
      http.statusCode == 401 || http.statusCode == 403
    else { return (data, response) }

    await invalidate(
      first,
      reason: "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
    return try await session.data(for: try makeRequest(try await token()))
  }
}
