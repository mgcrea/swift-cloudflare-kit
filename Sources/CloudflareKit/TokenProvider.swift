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

  public func token() async throws -> String {
    switch self {
    case .fixed(let value):
      return value
    case .renewing(let resolve):
      return try await resolve()
    }
  }
}
