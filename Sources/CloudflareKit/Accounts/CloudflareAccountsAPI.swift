import Foundation

/// `GET /accounts` — the accounts a credential covers.
///
/// Both consuming apps had their own copy of this on their own client, differing only in
/// which app-specific error they threw. The request is plain Cloudflare, so it lives here
/// and each app maps ``CloudflareAccountsError`` into its own vocabulary at the call site.
public enum CloudflareAccountsAPI {

  /// `per_page=1000` because there is no paging here and an account list is small; a user
  /// with more than a thousand accounts is not a case worth a cursor.
  static let endpoint = URL(
    string: "https://api.cloudflare.com/client/v4/accounts?per_page=1000")!

  struct ListResponse: Decodable {
    struct Account: Decodable {
      let id: String?
      let name: String?
    }
    struct Failure: Decodable {
      let message: String?
    }
    let success: Bool?
    let result: [Account]?
    let errors: [Failure]?
  }

  public static func list(
    token: String,
    session: URLSession = .shared
  ) async throws -> [CloudflareAccount] {
    var request = URLRequest(url: endpoint)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudflareAccountsError.invalidResponse
    }
    let decoded = try? JSONDecoder().decode(ListResponse.self, from: data)
    guard http.statusCode == 200 else {
      throw CloudflareAccountsError.http(
        status: http.statusCode, message: decoded?.errors?.first?.message ?? "")
    }
    guard let decoded, decoded.success != false, let result = decoded.result else {
      throw CloudflareAccountsError.http(
        status: http.statusCode, message: decoded?.errors?.first?.message ?? "")
    }
    return result.compactMap { account in
      guard let id = account.id else { return nil }
      return CloudflareAccount(id: id, name: account.name ?? id, grantedScopes: [])
    }
  }
}

public enum CloudflareAccountsError: LocalizedError, Equatable, Sendable {
  case invalidResponse
  case http(status: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse:
      "Cloudflare returned a response that could not be read."
    case .http(let status, let message):
      message.isEmpty
        ? "Cloudflare could not list your accounts (HTTP \(status))."
        : "Cloudflare could not list your accounts: \(message)"
    }
  }
}
