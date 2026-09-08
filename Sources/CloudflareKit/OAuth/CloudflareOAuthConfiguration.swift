import Foundation

/// Everything about an OAuth client that differs between apps.
///
/// This type is the whole point of the extraction. The flow itself — PKCE, the loopback
/// redirect, the state check, refresh, revocation — is identical in every consumer, and it
/// had been copied twice and drifted. What genuinely differs is four values, and they are
/// *not* incidental:
///
/// - **`clientID`** is registered per app. Sharing one would make users consent to another
///   app's name, list it under that name in Connected Applications, and — worse — revoking
///   one app's grant would silently revoke the other's.
/// - **`requiredScopes` / `optionalScopes`** differ because the apps do different things.
///   Asking for a scope the client is not registered for fails the whole authorization as
///   `invalid_scope`, so these cannot be unioned into one generous list.
/// - **`redirectPorts`** differ so two sibling apps signing in at once do not collide.
///   Cloudflare itself does not require this: it applies RFC 8252 §7.3, so the loopback
///   *port* is not matched against the registration (the path is). An earlier comment in
///   D1Explorer claimed the opposite and it was wrong.
/// - **`appName`** is shown in the browser tab the redirect lands on, where the user is
///   looking at a page outside the app and needs to be told which app to go back to.
public struct CloudflareOAuthConfiguration: Sendable, Hashable {

  /// The registered client id. Public and non-secret by construction — it identifies the
  /// app on the consent screen and nothing more.
  ///
  /// **This is a public client: there is no secret anywhere in a consuming app.** A shipped
  /// binary cannot keep one, so clients are registered with
  /// `token_endpoint_auth_method: "none"` and every leg is protected by PKCE instead. A
  /// `client_secret` must never appear in this package or in a consumer.
  public let clientID: String

  /// The app's name, as shown to a user who is currently looking at their browser.
  public let appName: String

  /// Scopes the consent screen will not let the user decline.
  public let requiredScopes: [String]

  /// Scopes registered in the client's `optional_scopes`, so Cloudflare renders them as
  /// declinable. A declined optional scope is not an error; it is a smaller grant, and the
  /// app should degrade rather than refuse to run.
  public let optionalScopes: [String]

  /// Candidate loopback ports, tried in order until one binds. Four is enough to survive a
  /// couple being taken.
  public let redirectPorts: [UInt16]

  /// An https redirect the app receives directly, when it has one registered.
  ///
  /// This is the alternative to the loopback listener, and on iOS it is the only one that
  /// actually works. `openURL` sends the user to Safari, which backgrounds the app; a
  /// suspended app's `NWListener` is not serviced, so the redirect completes its TCP
  /// handshake into the kernel backlog and is then never read. Sign-in ends in `.timedOut`
  /// after a wait that does not even advance while the app is suspended. An
  /// `ASWebAuthenticationSession` avoids the whole problem by presenting its web content
  /// in-process, so the app is never backgrounded — but its callback cannot be `http`,
  /// which is why this exists and why it is not simply the loopback URI with a scheme swap.
  ///
  /// Registering one is not free: Cloudflare's OAuth client form accepts only `http://` or
  /// `https://` (a custom scheme is rejected outright), and
  /// `ASWebAuthenticationSession.Callback.https(host:path:)` requires the host to be
  /// associated with the app through **`webcredentials:`** in the Associated Domains
  /// entitlement — not `applinks:`, which is the easy mistake. Both have to agree with the
  /// value here, and the path is matched by Cloudflare exactly.
  ///
  /// `nil` means loopback-only, which is correct for a CLI and fine on macOS.
  public let httpsCallback: HTTPSCallback?

  /// A registered https redirect: where Cloudflare sends the browser, and what the app is
  /// entitled to intercept.
  public struct HTTPSCallback: Sendable, Hashable {
    /// The host, e.g. `almanac.mgcrea.io`. Must match the Associated Domains entitlement.
    public let host: String
    /// The path, e.g. `/oauth/callback`. Matched exactly by Cloudflare, so it must match
    /// the redirect URL registered on the OAuth client character for character.
    public let path: String

    public init(host: String, path: String) {
      self.host = host
      self.path = path
    }

    /// The `redirect_uri` to send in the authorization request.
    public var redirectURI: String { "https://\(host)\(path)" }
  }

  /// Subsystem for this client's `Logger`, so a consumer's logs stay under its own name.
  public let loggingSubsystem: String

  public init(
    clientID: String,
    appName: String,
    requiredScopes: [String],
    optionalScopes: [String] = [],
    redirectPorts: [UInt16],
    loggingSubsystem: String,
    httpsCallback: HTTPSCallback? = nil
  ) {
    self.clientID = clientID
    self.appName = appName
    self.requiredScopes = requiredScopes
    self.optionalScopes = optionalScopes
    self.redirectPorts = redirectPorts
    self.loggingSubsystem = loggingSubsystem
    self.httpsCallback = httpsCallback
  }

  /// The protocol scope that asks for a refresh token. **Requesting it is not optional and
  /// not automatic.**
  ///
  /// Registering the client with `refresh_token` in `grant_types` only makes the scope
  /// *available*; the authorization request still has to ask for it. Omit it and Cloudflare
  /// happily returns an access token with no `refresh_token`, the grant dies at the first
  /// expiry, and the user is bounced back to the browser mid-session.
  public static let offlineAccessScope = "offline_access"

  /// What the authorization request actually asks for.
  ///
  /// `offline_access` is appended here rather than kept in `requiredScopes` because that
  /// list drives consent-screen copy and the "which scopes were declined" comparison, and
  /// it should stay a list of things the *app* does rather than protocol plumbing.
  public var allScopes: [String] {
    requiredScopes + optionalScopes + [Self.offlineAccessScope]
  }

  public func redirectURI(port: UInt16) -> String {
    "http://127.0.0.1:\(port)/callback"
  }
}
