import Foundation

/// The OAuth 2.0 authorization-code + PKCE flow against Cloudflare's dashboard.
///
/// Until June 2026 there was no way for a third-party app to hold a Cloudflare credential
/// except to ask the user to mint an API token by hand and paste it in. Cloudflare then
/// shipped self-serve *public* OAuth clients, and this is that flow. It is what lets a
/// sign-in sheet offer one button instead of a row of opaque strings.
///
/// The endpoints live on `dash.cloudflare.com`, **not** `api.cloudflare.com`. Only the
/// resulting access token is used against the v4 API, and there it is an ordinary
/// `Authorization: Bearer` — identical in shape to a pasted API token, which is why an
/// existing client needs no change beyond reading its token per request rather than at
/// init. See ``TokenProvider``.
///
/// A value rather than an enum of statics, because everything app-specific now arrives in
/// ``CloudflareOAuthConfiguration`` instead of being a hardcoded constant.
public struct CloudflareOAuth: Sendable {

  public let configuration: CloudflareOAuthConfiguration

  public init(configuration: CloudflareOAuthConfiguration) {
    self.configuration = configuration
  }

  // MARK: - Endpoints

  public static let authorizationEndpoint = URL(
    string: "https://dash.cloudflare.com/oauth2/auth")!
  public static let tokenEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
  public static let revocationEndpoint = URL(
    string: "https://dash.cloudflare.com/oauth2/revoke")!

  /// Where a user manages or withdraws the grant. Worth offering next to Sign Out, so
  /// revoking is never something only the app can do.
  public static let connectedApplications = URL(
    string: "https://dash.cloudflare.com/profile/authorized-apps")!

  // MARK: - Authorization URL (pure)

  /// Builds the URL the system browser is sent to. Pure, so tests can assert on it with no
  /// network and no browser.
  public func authorizationURL(
    state: String,
    challenge: String,
    redirectURI: String,
    scopes: [String]? = nil
  ) -> URL {
    var components = URLComponents(
      url: Self.authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      // Space-separated per RFC 6749; URLComponents percent-encodes it for us.
      URLQueryItem(
        name: "scope", value: (scopes ?? configuration.allScopes).joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components.url!
  }

  // MARK: - Token responses

  /// Cloudflare's token endpoint payload.
  ///
  /// `refreshToken` is optional because a refresh response is not obliged to reissue one;
  /// when it is absent the previously stored refresh token stays valid and must be kept.
  /// Dropping it on a nil would sign the user out at the next expiry.
  ///
  /// `scope` is what was actually *granted*, which is not necessarily what was asked for —
  /// this is where a declined optional scope shows up, and the only place an app can learn
  /// about it.
  public struct TokenResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case expiresIn = "expires_in"
      case refreshToken = "refresh_token"
      case scope
    }

    public init(accessToken: String, expiresIn: Int, refreshToken: String?, scope: String?) {
      self.accessToken = accessToken
      self.expiresIn = expiresIn
      self.refreshToken = refreshToken
      self.scope = scope
    }

    public var grantedScopes: [String] {
      (scope ?? "").split(separator: " ").map(String.init)
    }

    /// Absolute expiry, derived at the moment of decoding.
    ///
    /// Cloudflare publishes no fixed access-token lifetime and it is theirs to change, so
    /// `expires_in` is the only trustworthy source. Nothing here hardcodes a TTL.
    public var expiry: Date {
      Date().addingTimeInterval(TimeInterval(expiresIn))
    }
  }

  /// The OAuth error envelope (RFC 6749 §5.2), which is *not* Cloudflare's usual
  /// `{ success, errors[] }` v4 shape — these endpoints are on the dashboard, not the API.
  struct ErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
      case error
      case errorDescription = "error_description"
    }
  }

  // MARK: - Network legs

  /// Exchanges an authorization code for tokens.
  public func exchange(
    code: String,
    verifier: String,
    redirectURI: String,
    session: URLSession = .shared
  ) async throws -> TokenResponse {
    try await postForm(
      [
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirectURI,
        "client_id": configuration.clientID,
        "code_verifier": verifier,
      ], to: Self.tokenEndpoint, session: session)
  }

  /// Trades a refresh token for a fresh access token.
  ///
  /// No client secret — a public client authenticates with `client_id` alone. Cloudflare
  /// may rotate the refresh token here, which is why callers must persist
  /// `refreshToken ?? theOldOne` rather than assuming either.
  public func refresh(
    refreshToken: String,
    session: URLSession = .shared
  ) async throws -> TokenResponse {
    try await postForm(
      [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": configuration.clientID,
      ], to: Self.tokenEndpoint, session: session)
  }

  /// Withdraws a grant (RFC 7009).
  ///
  /// Call on sign-out *before* deleting local state. Deleting the Keychain item alone would
  /// leave a live grant on the account that the user believes they revoked, and the only
  /// way back would be the dashboard.
  public func revoke(token: String, session: URLSession = .shared) async throws {
    var request = URLRequest(url: Self.revocationEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      Self.formEncode(["token": token, "client_id": configuration.clientID]).utf8)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudflareOAuthError.invalidResponse
    }
    // RFC 7009 says revoking an already-invalid token is a success, so only a real failure
    // status is worth reporting.
    guard (200..<300).contains(http.statusCode) else {
      throw Self.decodeError(data: data, status: http.statusCode)
    }
  }

  private func postForm(
    _ fields: [String: String],
    to url: URL,
    session: URLSession
  ) async throws -> TokenResponse {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(Self.formEncode(fields).utf8)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudflareOAuthError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw Self.decodeError(data: data, status: http.statusCode)
    }
    do {
      return try JSONDecoder().decode(TokenResponse.self, from: data)
    } catch {
      throw CloudflareOAuthError.invalidResponse
    }
  }

  static func decodeError(data: Data, status: Int) -> CloudflareOAuthError {
    guard let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
      return .server(
        status: status, code: nil, message: String(data: data, encoding: .utf8) ?? "")
    }
    // `invalid_grant` is the one worth naming: the refresh token is spent or the grant was
    // revoked from the dashboard, and the fix is to sign in again rather than to retry.
    if decoded.error == "invalid_grant" {
      return .grantExpired
    }
    return .server(status: status, code: decoded.error, message: decoded.errorDescription ?? "")
  }

  /// `application/x-www-form-urlencoded`, with the query-item allowed set narrowed.
  ///
  /// `.urlQueryAllowed` permits `+` and `&`, which are structural in a form body — a
  /// verifier or token containing either would silently split into extra fields. Sorted so
  /// a request body is reproducible in a test.
  public static func formEncode(_ fields: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.keys.sorted().map { key in
      let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let value = fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      return "\(name)=\(value)"
    }.joined(separator: "&")
  }
}
