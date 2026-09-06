import Foundation
import Observation
import os

/// Serializes token refreshes so a burst of concurrent requests mints one token, not N.
///
/// This is the reason the store is not simply a set of `async` methods on the `@Observable`
/// class. On launch several views fire at once against the same account; if each saw an
/// expired token and refreshed independently, Cloudflare would rotate the refresh token
/// several times and all but one of those exchanges would invalidate the rest. The user
/// would be signed out by their own app opening a window.
actor TokenStore {
  private var cache: [String: (value: String, expiry: Date)] = [:]
  private var inFlight: [String: Task<CloudflareOAuth.TokenResponse, Error>] = [:]

  /// How long before expiry a token is treated as already spent. A token that passes the
  /// check and then expires mid-request comes back as a 401 the user sees; sixty seconds
  /// covers a slow request on a bad connection.
  static let refreshMargin: TimeInterval = 60

  /// A live access token for `accountID`, minting one through `mint` if the cached token is
  /// missing or close to expiring. Returns `nil` when the cached token is still good — the
  /// caller keeps using what it has.
  ///
  /// The whole cache lives inside this actor rather than on the `@Observable` store, which
  /// is what makes it safe: a client reads a token from whatever context its request
  /// happens to run on, and an unprotected dictionary would be a data race.
  func token(
    for accountID: String,
    mint: @escaping @Sendable () async throws -> CloudflareOAuth.TokenResponse
  ) async throws -> CloudflareOAuth.TokenResponse? {
    if let cached = cache[accountID], cached.expiry.timeIntervalSinceNow > Self.refreshMargin {
      return nil
    }
    if let existing = inFlight[accountID] {
      return try await existing.value
    }
    let task = Task { try await mint() }
    inFlight[accountID] = task
    defer { inFlight[accountID] = nil }
    let response = try await task.value
    cache[accountID] = (response.accessToken, response.expiry)
    return response
  }

  func cachedToken(for accountID: String) -> String? {
    guard let cached = cache[accountID],
      cached.expiry.timeIntervalSinceNow > Self.refreshMargin
    else { return nil }
    return cached.value
  }

  func adopt(_ response: CloudflareOAuth.TokenResponse, for accountID: String) {
    cache[accountID] = (response.accessToken, response.expiry)
  }

  func forget(_ accountID: String) {
    cache[accountID] = nil
  }
}

/// The Cloudflare accounts a user has signed in to, and their OAuth grants.
///
/// `@Observable`, so a consuming app injects it through `@Environment` and its views
/// observe `accounts` directly.
///
/// Everything app-shaped is injected through ``Dependencies`` rather than imported: the
/// Keychain is three closures, the storage location is a URL, and listing accounts is the
/// package's own `GET /accounts`. That is what lets the same store back two apps whose
/// Keychain namespaces, storage directories and connection models all differ.
/// `@unchecked Sendable` because `tokenProvider(for:)` hands a closure holding `self` to a
/// client that calls it from whatever context its request runs on.
///
/// Every **mutation** of `accounts` is `@MainActor`: `signIn`, `signOut`, `forget`,
/// `upsert` and `applyGrantedScopes`. The token cache is inside ``TokenStore``, an actor.
///
/// The remaining sharp edge, stated rather than papered over: `accessToken(for:)` is not
/// main-actor isolated — it cannot be, since clients call it from arbitrary contexts — and
/// it *reads* `accounts` to find the account's Keychain key. That read is inherited from
/// both apps' existing implementations rather than introduced here, and in practice the
/// array is tiny and rewritten wholesale. It is worth closing by moving the id-to-key
/// mapping into the actor, and that is a change to make deliberately, not as a side effect
/// of an extraction.
@Observable
public final class CloudflareAccountStore: @unchecked Sendable {

  /// The app-shaped seams. Closures rather than a protocol so a consumer can pass its
  /// existing Keychain helper without conforming it to anything.
  public struct Dependencies: Sendable {
    public var oauth: CloudflareOAuth
    /// Namespaces this app's grant refresh tokens, e.g. `"com.swiftd1.oauth."`. Must differ
    /// from whatever the app uses for pasted per-connection tokens.
    public var keychainKeyPrefix: String
    public var readSecret: @Sendable (String) throws -> String
    public var saveSecret: @Sendable (String, String, Bool) throws -> Void
    public var deleteSecret: @Sendable (String) -> Void
    /// Whether new Keychain writes should be marked synchronizable. Read at write time, so
    /// flipping the app's setting does not retroactively move stored credentials.
    public var isSynchronizable: @Sendable () -> Bool
    public var session: URLSession

    public init(
      oauth: CloudflareOAuth,
      keychainKeyPrefix: String,
      readSecret: @escaping @Sendable (String) throws -> String,
      saveSecret: @escaping @Sendable (String, String, Bool) throws -> Void,
      deleteSecret: @escaping @Sendable (String) -> Void,
      isSynchronizable: @escaping @Sendable () -> Bool,
      session: URLSession = .shared
    ) {
      self.oauth = oauth
      self.keychainKeyPrefix = keychainKeyPrefix
      self.readSecret = readSecret
      self.saveSecret = saveSecret
      self.deleteSecret = deleteSecret
      self.isSynchronizable = isSynchronizable
      self.session = session
    }
  }

  public var accounts: [CloudflareAccount] = []

  /// Access tokens, in memory only and behind an actor. They live minutes and are cheap to
  /// re-mint, so persisting them would buy nothing and widen what a stolen disk yields.
  @ObservationIgnored private let tokens = TokenStore()
  @ObservationIgnored private let storageURL: URL
  @ObservationIgnored private let dependencies: Dependencies
  @ObservationIgnored private let log: Logger

  /// - Parameter storageURL: where `accounts.json` lives. Accounts are deliberately kept in
  ///   their own file rather than inside a connections file: that one is often a bare array
  ///   mirrored through iCloud key-value storage, and wrapping it in an envelope to make
  ///   room here would break decoding for every older build reading the same record. A
  ///   separate file is additive — an older build simply never looks for it.
  /// - Parameter loadsFromDisk: pass `false` for a demo or screenshot build, so the store
  ///   starts empty instead of reading the real `accounts.json`. Without it a screenshot run
  ///   on a developer's machine renders that developer's actual Cloudflare account names,
  ///   and a golden-image gate fails for a reason nothing on screen explains.
  public init(storageURL: URL, dependencies: Dependencies, loadsFromDisk: Bool = true) {
    self.storageURL = storageURL
    self.dependencies = dependencies
    self.log = Logger(
      subsystem: dependencies.oauth.configuration.loggingSubsystem,
      category: "CloudflareAccountStore")
    if loadsFromDisk { load() }
  }

  private func keychainKey(for account: CloudflareAccount) -> String {
    account.keychainKey(prefix: dependencies.keychainKeyPrefix)
  }

  // MARK: - Lookup

  public func account(id: String) -> CloudflareAccount? {
    accounts.first { $0.id == id }
  }

  // MARK: - Sign in

  /// Runs the full authorization-code + PKCE flow and returns the accounts it unlocked.
  ///
  /// `openURL` is injected rather than imported, so this file holds no SwiftUI: the caller
  /// passes `SwiftUI.openURL` (or `NSWorkspace.shared.open`) in. The browser is the real
  /// system browser, not an embedded session — see ``LoopbackRedirectListener`` for why
  /// `ASWebAuthenticationSession` cannot serve a loopback redirect.
  ///
  /// - Parameter aroundWait: wraps the wait for the redirect. On iOS the caller passes a
  ///   background-task assertion here: opening the browser backgrounds the app, and a
  ///   suspended app's `NWListener` stops accepting, so the redirect would land on a dead
  ///   socket and the flow would end in `.timedOut` with nothing to explain it. On macOS
  ///   the app stays running and the default passthrough is right.
  @MainActor
  public func signIn(
    openURL: @escaping (URL) -> Void,
    aroundWait: (@Sendable (@Sendable () async throws -> String) async throws -> String)? = nil
  ) async throws -> [CloudflareAccount] {
    let oauth = dependencies.oauth
    let listener = LoopbackRedirectListener(configuration: oauth.configuration)
    let state = PKCE.makeState()
    let port = try listener.start(expectedState: state)
    let redirectURI = oauth.configuration.redirectURI(port: port)
    let pkce = PKCE()

    openURL(
      oauth.authorizationURL(
        state: state, challenge: pkce.challenge, redirectURI: redirectURI))

    let wait: @Sendable () async throws -> String = { try await listener.waitForCode() }
    let code: String
    if let aroundWait {
      code = try await aroundWait(wait)
    } else {
      code = try await wait()
    }

    let response = try await oauth.exchange(
      code: code,
      verifier: pkce.verifier,
      redirectURI: redirectURI,
      session: dependencies.session)

    // The grant is account-agnostic until we ask which accounts it covers. Everything else
    // needs an account id in the URL path, so this is not optional.
    //
    // Checked before the refresh token, matching the order both apps used: a grant that
    // covers nothing is almost always a missing account-listing scope, and saying so is
    // more useful than reporting the refresh problem the user would hit next.
    let listed = try await CloudflareAccountsAPI.list(
      token: response.accessToken, session: dependencies.session)
    guard !listed.isEmpty else {
      log.error("Grant covers no accounts — check the account-listing scope")
      throw CloudflareOAuthError.noAccounts
    }

    guard let refreshToken = response.refreshToken else {
      // Without one, the grant dies at the first expiry and the user is bounced back to
      // the browser mid-session. Better to fail now, while they are still here. If this
      // fires, `offline_access` is missing from the authorization request.
      log.error("Token response carried no refresh token — is offline_access requested?")
      throw CloudflareOAuthError.noRefreshToken
    }

    let synchronizable = dependencies.isSynchronizable()
    var unlocked: [CloudflareAccount] = []
    for var account in listed {
      account.grantedScopes = response.grantedScopes
      try dependencies.saveSecret(
        refreshToken, keychainKey(for: account), synchronizable)
      upsert(account)
      unlocked.append(account)
      await tokens.adopt(response, for: account.id)
    }
    save()
    log.info(
      """
      Signed in to \(unlocked.count) Cloudflare account(s), \
      scopes: \(response.grantedScopes.joined(separator: " "))
      """)
    return unlocked
  }

  @MainActor
  private func upsert(_ account: CloudflareAccount) {
    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
      accounts[index] = account
    } else {
      accounts.append(account)
    }
  }

  // MARK: - Sign out

  /// Revokes the grant with Cloudflare, then forgets every account it covered.
  ///
  /// **Signing out is grant-shaped, not account-shaped.** One authorization can unlock
  /// several Cloudflare accounts, and they share one refresh token — so revoking it on
  /// behalf of one account silently kills the others too. Forgetting only the named account
  /// would leave the rest looking signed in and failing on their next request, with nothing
  /// in the UI to explain it. ``accountsSharingGrant(with:)`` is what makes the local state
  /// match what Cloudflare just did.
  ///
  /// Revocation goes first on purpose: deleting only local state would leave a live grant
  /// the user believes they cancelled, recoverable only from the dashboard. If the call
  /// fails the local state is still cleared — someone who asked to sign out must end up
  /// signed out — and the error is rethrown so the caller can point them at Connected
  /// Applications to finish the job.
  @MainActor
  public func signOut(accountID: String) async throws {
    let affected = accountsSharingGrant(with: accountID)
    defer { for id in affected { forget(accountID: id) } }

    guard let account = account(id: accountID),
      let refreshToken = try? dependencies.readSecret(keychainKey(for: account))
    else { return }
    try await dependencies.oauth.revoke(token: refreshToken, session: dependencies.session)
  }

  /// Every account whose stored refresh token is the one `accountID` holds — that is, every
  /// account unlocked by the same sign-in. Always includes `accountID` itself.
  @MainActor
  public func accountsSharingGrant(with accountID: String) -> [String] {
    guard let account = account(id: accountID),
      let token = try? dependencies.readSecret(keychainKey(for: account))
    else { return [accountID] }
    return
      accounts
      .filter { (try? dependencies.readSecret(keychainKey(for: $0))) == token }
      .map(\.id)
  }

  @MainActor
  private func forget(accountID: String) {
    if let account = account(id: accountID) {
      dependencies.deleteSecret(keychainKey(for: account))
    }
    let store = tokens
    Task { await store.forget(accountID) }
    accounts.removeAll { $0.id == accountID }
    save()
  }

  // MARK: - Access tokens

  /// A valid access token for `accountID`, refreshing if the cached one is spent.
  ///
  /// This is what `TokenProvider.renewing` calls on every request. It is cheap in the
  /// common case — a dictionary read and a date comparison — and only crosses the network
  /// when the margin is breached.
  public func accessToken(for accountID: String) async throws -> String {
    if let cached = await tokens.cachedToken(for: accountID) {
      return cached
    }
    guard let account = account(id: accountID) else {
      throw CloudflareOAuthError.grantExpired
    }
    let key = keychainKey(for: account)
    let stored = try dependencies.readSecret(key)
    let synchronizable = dependencies.isSynchronizable()
    let oauth = dependencies.oauth
    let session = dependencies.session
    let saveSecret = dependencies.saveSecret

    // Returns nil when another caller refreshed while this one was waiting — the token it
    // minted is already cached, so fall through and read it.
    guard
      let response = try await tokens.token(
        for: accountID,
        mint: {
          let response = try await oauth.refresh(refreshToken: stored, session: session)
          // Cloudflare may or may not rotate the refresh token. Writing
          // `response.refreshToken` unconditionally would overwrite a perfectly good stored
          // token with nothing on the responses that reuse the old one, signing the user
          // out at the following expiry.
          if let rotated = response.refreshToken, rotated != stored {
            try saveSecret(rotated, key, synchronizable)
          }
          return response
        })
    else {
      guard let cached = await tokens.cachedToken(for: accountID) else {
        throw CloudflareOAuthError.grantExpired
      }
      return cached
    }

    // A refresh reports the scopes still in force. If the user narrowed the grant from the
    // Cloudflare dashboard, this is where the app finds out. Hopped to the main actor
    // because `accounts` is observed by the UI and written from it everywhere else.
    if !response.grantedScopes.isEmpty {
      let granted = response.grantedScopes
      await MainActor.run { self.applyGrantedScopes(granted, to: accountID) }
    }
    return response.accessToken
  }

  @MainActor
  private func applyGrantedScopes(_ scopes: [String], to accountID: String) {
    guard let index = accounts.firstIndex(where: { $0.id == accountID }),
      accounts[index].grantedScopes != scopes
    else { return }
    accounts[index].grantedScopes = scopes
    save()
  }

  /// A provider a client can hold. Reads through ``accessToken(for:)`` per request, so a
  /// long-lived client never goes stale.
  public func tokenProvider(for accountID: String) -> TokenProvider {
    .renewing { [weak self] in
      guard let self else { throw CloudflareOAuthError.grantExpired }
      return try await self.accessToken(for: accountID)
    }
  }

  // MARK: - Persistence

  private func load() {
    guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
    do {
      let data = try Data(contentsOf: storageURL)
      accounts = try JSONDecoder().decode([CloudflareAccount].self, from: data)
    } catch {
      // Nothing here is irreplaceable: the refresh tokens are in the Keychain and the rest
      // is re-derivable by signing in again. So this logs and starts empty rather than
      // preserving a corrupt file.
      log.error("Failed to load accounts: \(error.localizedDescription)")
      accounts = []
    }
  }

  /// Internal rather than private so tests can persist without a network round trip.
  func save() {
    do {
      let data = try JSONEncoder().encode(accounts)
      try data.write(to: storageURL, options: .atomic)
    } catch {
      log.error("Failed to save accounts: \(error.localizedDescription)")
    }
  }
}
