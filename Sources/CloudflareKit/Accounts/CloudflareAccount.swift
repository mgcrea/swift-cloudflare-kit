import Foundation

/// A Cloudflare account the user has signed in to, and the grant that covers it.
///
/// An OAuth grant is account-shaped: one authorization covers every resource in the
/// account, where a pasted API token was stored per connection. Keeping a per-connection
/// layout for OAuth would mean N copies of one credential, each refreshing on its own
/// schedule and invalidating the others when Cloudflare rotates the refresh token.
///
/// Deliberately holds **no token and no expiry**. The refresh token lives in the Keychain;
/// the access token is never persisted — it expires in minutes and is cheap to re-mint, so
/// writing it to disk would be storage risk bought for nothing. Its expiry is not persisted
/// either, and that follows: the in-memory cache starts empty on every launch, so the first
/// request after a relaunch refreshes regardless of what a stored date said.
///
/// The app-specific parts stay in the app as extensions — which scope means "can write",
/// the Keychain key prefix, and how an account maps to that app's connection model.
public struct CloudflareAccount: Identifiable, Codable, Equatable, Hashable, Sendable {

  /// Cloudflare's own account id — the `{account_id}` path segment in every v4 URL, and the
  /// same string a user pastes into a manual form. Using it as the identity means an OAuth
  /// account and a hand-configured connection to the same account agree on one id.
  public var id: String

  /// Display name from `GET /accounts`. Cosmetic: a picker shows this, never the id.
  public var name: String

  /// What Cloudflare actually granted, which is not necessarily what was requested — the
  /// consent screen lets every optional scope be declined.
  ///
  /// Recorded so the UI can answer "why is that panel missing?" without a probe. It is a
  /// record of a *grant*, not of a token's capabilities: a scope list returned by the
  /// authorization server is a fact about the authorization, and it goes stale only when
  /// the user re-authorizes, which happens through the app.
  public var grantedScopes: [String]

  public init(id: String, name: String, grantedScopes: [String] = []) {
    self.id = id
    self.name = name
    self.grantedScopes = grantedScopes
  }

  /// Keychain account for this grant's refresh token.
  ///
  /// The prefix is the caller's, and must be namespaced apart from whatever the app uses
  /// for pasted per-connection tokens, so a connection id and an account id can never
  /// collide and a migration can tell the two kinds apart by key alone.
  public func keychainKey(prefix: String) -> String { prefix + id }

  /// Optional scopes that were asked for and not granted.
  public func declinedScopes(against configuration: CloudflareOAuthConfiguration) -> [String] {
    configuration.optionalScopes.filter { !grantedScopes.contains($0) }
  }
}
