import Foundation

/// The Cloudflare GraphQL analytics endpoint, and its two traps.
///
/// Both consuming apps reimplemented this, and the copies had drifted in ways that changed
/// behaviour rather than just wording:
///
/// | | D1Explorer | R2Explorer |
/// | --- | --- | --- |
/// | `message` | `String?` | `String` |
/// | several errors | reported `.first` | joined with `"; "` |
/// | accepted status | `200` only | `200...299` |
/// | permission words | 6, including `not entitled`, `access denied` | 6, including `unauthorised`, `not authorized` |
///
/// The last row is the one that mattered: the same Cloudflare response could read as a
/// fixable instruction in one app and as a generic failure in the other. This version takes
/// the **union** of both word lists, joins all messages, and accepts `200...299`.
public enum CloudflareGraphQL {

  public static let endpoint = URL(string: "https://api.cloudflare.com/client/v4/graphql")!

  /// The response envelope, generic over its payload.
  ///
  /// Every leaf is `Optional` because a permission failure arrives as **HTTP 200 with
  /// `data: null`** and a populated `errors` array. A decoder that required any field would
  /// throw a `DecodingError` over the top of the message the user actually needs to read.
  public struct Envelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    public struct Failure: Decodable, Sendable {
      public let message: String?
      public let path: [String]?
    }
    public let data: Payload?
    public let errors: [Failure]?
  }

  /// The `viewer { accounts { … } }` shape every account-scoped query returns.
  ///
  /// The account type is lowercase `account` and the viewer type lowercase `viewer`;
  /// `__type(name: "Account")` returns `null`, which reads exactly like "no such thing" and
  /// has already cost one reader a wrong conclusion about what this API offers.
  public struct AccountsPayload<Account: Decodable & Sendable>: Decodable, Sendable {
    public struct Viewer: Decodable, Sendable {
      public let accounts: [Account]?
    }
    public let viewer: Viewer?
    public var first: Account? { viewer?.accounts?.first }
  }

  /// Resolves an envelope from a response body, throwing before `data` is trusted.
  ///
  /// The status code is deliberately not a parameter here: on this endpoint it proves
  /// nothing, and a caller that had checked it would still have to do all of this.
  public static func payload<Payload: Decodable & Sendable>(
    _ type: Payload.Type = Payload.self,
    from body: Data
  ) throws -> Payload? {
    let envelope: Envelope<Payload>
    do {
      envelope = try JSONDecoder().decode(Envelope<Payload>.self, from: body)
    } catch {
      throw CloudflareGraphQLError.invalidResponse
    }

    let messages = (envelope.errors ?? []).compactMap(\.message)
    if !messages.isEmpty {
      let detail = messages.joined(separator: "; ")
      if messages.contains(where: isPermissionMessage) {
        throw CloudflareGraphQLError.unauthorized(detail: detail)
      }
      throw CloudflareGraphQLError.server(status: 200, detail: detail)
    }
    return envelope.data
  }

  /// Whether a GraphQL error message describes a missing permission.
  ///
  /// Cloudflare gives permission failures no stable code in this array, so the message is
  /// matched instead. Kept deliberately broad, and the list is the union of the two the
  /// consuming apps had drifted into: mislabelling a permission error as a generic failure
  /// sends the user hunting for a bug that does not exist, while the reverse only shows a
  /// token hint that turns out not to help.
  ///
  /// Both spellings of every "authoris/zed" wording are present. Cloudflare is not
  /// consistent about it, and a British-spelled message reading as a generic failure is the
  /// exact bug this list exists to prevent.
  public static func isPermissionMessage(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return [
      "permission", "unauthorized", "unauthorised", "not authorized", "not authorised",
      "authentication", "not entitled", "forbidden", "access denied",
    ].contains { lowered.contains($0) }
  }

  /// POSTs a query and decodes the payload.
  ///
  /// - Parameter token: read per request rather than captured, so an OAuth access token
  ///   that expires mid-session is refreshed rather than reported as a revoked credential.
  ///   See ``TokenProvider``.
  public static func execute<Payload: Decodable & Sendable>(
    query: String,
    variables: [String: String] = [:],
    token: TokenProvider,
    session: URLSession = .shared
  ) async throws -> Payload? {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(try await token.token())", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "query": query,
      "variables": variables,
    ])

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudflareGraphQLError.invalidResponse
    }
    // A 401/403 is unambiguous and worth distinguishing from a 200 carrying an errors
    // array, even though both mean the same thing to a user.
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw CloudflareGraphQLError.unauthorized(
          detail: String(data: data, encoding: .utf8) ?? "")
      }
      throw CloudflareGraphQLError.server(
        status: http.statusCode, detail: String(data: data, encoding: .utf8) ?? "")
    }
    return try payload(Payload.self, from: data)
  }
}

/// Why a GraphQL analytics call failed.
public enum CloudflareGraphQLError: LocalizedError, Equatable, Sendable {
  /// The credential cannot read analytics. Almost always a token that is scoped for the
  /// thing the user came for but not for **Account Analytics: Read**, which is a separate
  /// permission and the commonest first-run outcome.
  case unauthorized(detail: String)
  case server(status: Int, detail: String)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .unauthorized:
      "This API token can't read analytics."
    case .server(let status, let detail):
      detail.isEmpty
        ? "Cloudflare returned an error (HTTP \(status))."
        : "Cloudflare returned an error: \(detail)"
    case .invalidResponse:
      "Cloudflare's response wasn't in a format this app understands."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .unauthorized:
      "Edit the token in the Cloudflare dashboard and add the \u{201C}Account Analytics: "
        + "Read\u{201D} permission, then update it here."
    case .server, .invalidResponse:
      nil
    }
  }
}
