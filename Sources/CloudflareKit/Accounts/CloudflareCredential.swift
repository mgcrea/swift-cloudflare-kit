import Foundation

/// How one connection or account authenticates: a token the user pasted, or a Cloudflare
/// sign-in shared with every other entry on the same account.
///
/// D1Explorer and R2Explorer each had this enum as `ConnectionCredential`, with these exact
/// case names. They are kept verbatim because the synthesized `Codable` form is on disk in
/// both apps; renaming a case would make every stored connection fail to decode.
public enum CloudflareCredential: Codable, Equatable, Hashable, Sendable {
  /// A pasted API token. Where it is stored is the app's decision: D1 and R2 key it by
  /// connection, KVExplorer by account.
  case pastedToken
  /// A Cloudflare sign-in. The refresh token lives in the account store, not here.
  case oauth(accountId: String)

  /// The provider a client should hold for this credential.
  ///
  /// - Parameter pastedToken: reads the app's own Keychain slot. Called only for
  ///   `.pastedToken`, and its error is rethrown as is, so a missing token still reads as
  ///   "not found in Keychain".
  /// - Parameter accounts: the app's account store, or nil where sign-in is unavailable.
  public func tokenProvider(
    pastedToken: () throws -> String,
    accounts: CloudflareAccountStore?
  ) throws -> TokenProvider {
    switch self {
    case .pastedToken:
      return .fixed(try pastedToken())
    case .oauth(let accountID):
      guard let accounts, accounts.account(id: accountID) != nil else {
        throw CloudflareCredentialError.signedOut(accountID: accountID)
      }
      return accounts.tokenProvider(for: accountID)
    }
  }
}

/// Why a credential could not produce a provider.
public enum CloudflareCredentialError: LocalizedError, Equatable, Sendable {
  /// The sign-in this credential names is no longer in the account store: signed out here,
  /// or signed out alongside another account from the same sign-in.
  case signedOut(accountID: String)

  public var errorDescription: String? {
    switch self {
    case .signedOut:
      "This account is signed out. Sign in with Cloudflare again to reach it."
    }
  }
}
