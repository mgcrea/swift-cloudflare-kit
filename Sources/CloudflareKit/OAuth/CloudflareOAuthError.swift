import Foundation

/// Why an OAuth flow failed, in the terms a UI needs to react differently.
///
/// The copy here is deliberately app-neutral. Both extracted copies named their own app in
/// five of these strings ("D1Explorer could not open a local port…"), which cannot survive
/// a shared package and reads no better for it — the user is already inside the app when
/// they see this. The one place the name genuinely matters is the page left in the
/// browser, and that takes it from ``CloudflareOAuthConfiguration/appName``.
public enum CloudflareOAuthError: LocalizedError, Equatable, Sendable {
  /// The user closed the browser, or Cloudflare returned `access_denied`.
  case cancelled
  /// The `state` that came back did not match the one sent. Treated as hostile.
  case stateMismatch
  /// No loopback port in the configuration could be bound.
  case noAvailablePort
  case timedOut
  case invalidResponse
  /// Cloudflare issued an access token but no refresh token.
  ///
  /// Split out from `.invalidResponse` after it cost an afternoon: sign-in had worked
  /// perfectly in the browser, and the app reported only "a response that could not be
  /// read" — true of four different failures and useful for none. In practice this means
  /// `offline_access` was missing from the request.
  case noRefreshToken
  /// The grant is valid but covers no Cloudflare accounts, so there is no `{account_id}`
  /// to put in any other URL. Almost always a missing account-listing scope.
  case noAccounts
  /// The refresh token is spent, or the grant was revoked outside the app.
  case grantExpired
  case server(status: Int, code: String?, message: String)

  public var errorDescription: String? {
    switch self {
    case .cancelled:
      "Sign-in was cancelled."
    case .stateMismatch:
      "The sign-in response did not match the request and was rejected."
    case .noAvailablePort:
      "Could not open a local port to complete sign-in."
    case .timedOut:
      "Sign-in timed out."
    case .invalidResponse:
      "Cloudflare returned a sign-in response that could not be read."
    case .noRefreshToken:
      "Cloudflare granted access but would not let it be kept."
    case .noAccounts:
      "That Cloudflare sign-in does not cover any accounts this app can read."
    case .grantExpired:
      "This Cloudflare sign-in is no longer valid."
    case .server(_, let code, let message):
      {
        let detail = message.isEmpty ? (code ?? "") : message
        return detail.isEmpty
          ? "Cloudflare rejected the sign-in request."
          : "Cloudflare rejected the sign-in request: \(detail)"
      }()
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .noRefreshToken:
      "Without that, you would be sent back to the browser every time the session expired. "
        + "Sign in again, and if it keeps happening the app is not requesting offline access."
    case .noAccounts:
      "Check that your Cloudflare user is a member of at least one account, then sign in "
        + "again."
    case .grantExpired:
      "Sign in to Cloudflare again. If you revoked this app's access, you will be asked to "
        + "approve it once more."
    case .stateMismatch:
      "Try signing in again. If this keeps happening, sign in from a browser window with no "
        + "other Cloudflare tabs open."
    case .noAvailablePort:
      "Another app may be holding the ports this app uses. Quit any running `wrangler login` "
        + "and try again."
    default:
      nil
    }
  }
}
