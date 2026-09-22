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

  /// The pauses, in seconds, before resending a refused token: seven and a half in all.
  ///
  /// Past the few seconds a new token has been measured to take, short enough that a token
  /// that really was revoked is reported without a long hang.
  public static let refusalBackoff: [Double] = [0.5, 1, 2, 4]

  /// Sends a request with this provider's token and, if Cloudflare refuses it with a 401 or
  /// 403, sends the **same** token again on a backoff before replacing it with a fresh one.
  ///
  /// **The same token first.** Cloudflare refuses a token minted a second ago for every
  /// account of a grant but the first one it is used on, then accepts that same token a few
  /// seconds later: measured in KVExplorer as 401s with 3598 of 3600 seconds left, on the
  /// second and third accounts only. Dropping it and minting another only restarts the
  /// wait. A token still refused once `refusalBackoff` runs out is replaced, once; a
  /// refusal of the fresh one is a real permission problem and comes back to the caller as
  /// the response it is. A provider that cannot refresh is never retried: it would send the
  /// same refused string again.
  ///
  /// `makeRequest` receives the bearer token rather than a finished request, so a retry
  /// carries the new token and nothing else changes.
  public func data(
    for makeRequest: (_ bearer: String) throws -> URLRequest, session: URLSession,
    refusalBackoff: [Double] = TokenProvider.refusalBackoff
  ) async throws -> (Data, URLResponse) {
    try await data(
      for: makeRequest, send: { try await session.data(for: $0) },
      refusalBackoff: refusalBackoff)
  }

  /// ``data(for:session:refusalBackoff:)`` for a client that sends through its own
  /// transport rather than a `URLSession`.
  public func data(
    for makeRequest: (_ bearer: String) throws -> URLRequest,
    send: (URLRequest) async throws -> (Data, URLResponse),
    refusalBackoff: [Double] = TokenProvider.refusalBackoff
  ) async throws -> (Data, URLResponse) {
    let first = try await token()
    let request = try makeRequest(first)
    var (data, response) = try await send(request)
    guard canRefresh, Self.isRefusal(response) else { return (data, response) }

    for delay in refusalBackoff {
      try await Task.sleep(for: .seconds(delay))
      (data, response) = try await send(request)
      guard Self.isRefusal(response) else { return (data, response) }
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    await invalidate(
      first, reason: "HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
    return try await send(try makeRequest(try await token()))
  }

  private static func isRefusal(_ response: URLResponse) -> Bool {
    guard let http = response as? HTTPURLResponse else { return false }
    return http.statusCode == 401 || http.statusCode == 403
  }
}
