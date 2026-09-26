import CloudflareKit
import Foundation
import Observation

/// What adding an account produced.
public enum AddAccountResult: Equatable, Sendable {
  /// Every account the sign-in's grant unlocked. The store has already saved them.
  case signedIn([CloudflareAccount])
  /// A token that listed (or was given) its account and passed the app's own check. Storing
  /// it is the app's job, keyed however the app keys pasted tokens.
  case pastedToken(token: String, account: CloudflareAccount)
}

/// The state and decisions behind ``AddAccountForm``, kept out of the view so every branch
/// is testable without one.
@MainActor
@Observable
public final class AddAccountModel {
  public var token = ""
  public var accountID = ""
  /// Accounts the pasted token covers, when there is more than one to choose from.
  public private(set) var candidates: [CloudflareAccount] = []
  public var selectedCandidateID: String?
  public var isSigningIn = false
  public var isAdding = false
  public private(set) var error: String?
  /// Set by the form from the store, so the button reads "Sign in to Another Account…".
  public var hasSignedInBefore = false

  public var canSignIn: Bool { signInAction != nil }

  public var signInTitle: String {
    if isSigningIn { return "Waiting for Cloudflare…" }
    return hasSignedInBefore ? "Sign in to Another Account…" : "Sign in with Cloudflare"
  }

  @ObservationIgnored private let signInAction:
    (@MainActor () async throws -> [CloudflareAccount])?
  @ObservationIgnored private let listAccounts:
    @Sendable (String) async throws -> [CloudflareAccount]
  @ObservationIgnored private let verify: @Sendable (String, String) async throws -> Void
  @ObservationIgnored private let onReviewDemo: (@MainActor () -> Void)?
  @ObservationIgnored private let onFinish: @MainActor (AddAccountResult) -> Void

  /// - Parameter signIn: nil hides "Sign in with Cloudflare", for a build without an OAuth
  ///   registration or a demo store.
  /// - Parameter verify: the app's own check that the token can do the app's job (list
  ///   namespaces, buckets or databases), so a token without the right permission fails
  ///   here rather than later in the sidebar.
  /// - Parameter onReviewDemo: nil inside the demo itself, where the trigger is just text.
  public init(
    signIn: (@MainActor () async throws -> [CloudflareAccount])?,
    listAccounts: @escaping @Sendable (String) async throws -> [CloudflareAccount],
    verify: @escaping @Sendable (String, String) async throws -> Void,
    onReviewDemo: (@MainActor () -> Void)?,
    onFinish: @escaping @MainActor (AddAccountResult) -> Void
  ) {
    self.signInAction = signIn
    self.listAccounts = listAccounts
    self.verify = verify
    self.onReviewDemo = onReviewDemo
    self.onFinish = onFinish
  }

  /// The production wiring: sign in through the store's in-app session, list accounts with
  /// `GET /accounts`.
  public convenience init(
    accounts: CloudflareAccountStore?,
    verify: @escaping @Sendable (String, String) async throws -> Void,
    onReviewDemo: (@MainActor () -> Void)?,
    onFinish: @escaping @MainActor (AddAccountResult) -> Void
  ) {
    self.init(
      signIn: accounts.map { store -> @MainActor () async throws -> [CloudflareAccount] in
        { try await store.signInWithWebSession() }
      },
      listAccounts: { try await CloudflareAccountsAPI.list(token: $0) },
      verify: verify,
      onReviewDemo: onReviewDemo,
      onFinish: onFinish)
    hasSignedInBefore = !(accounts?.accounts.isEmpty ?? true)
  }

  /// Called by the form whenever the token text changes: a pick made for one token must
  /// never be applied to another.
  public func tokenDidChange() {
    candidates = []
    selectedCandidateID = nil
    error = nil
  }

  public func signIn() async {
    guard let signInAction, !isSigningIn, !isAdding else { return }
    error = nil
    isSigningIn = true
    defer { isSigningIn = false }
    do {
      onFinish(.signedIn(try await signInAction()))
    } catch CloudflareOAuthError.cancelled {
      // Closing the sign-in sheet is an answer, not an error.
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func addToken() async {
    guard !isAdding, !isSigningIn else { return }
    if let onReviewDemo, CloudflareReviewDemo.isTrigger(token) {
      token = ""
      tokenDidChange()
      onReviewDemo()
      return
    }
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      error = "Paste an API token first."
      return
    }
    error = nil
    isAdding = true
    defer { isAdding = false }
    do {
      guard let account = try await resolveAccount(token: token) else { return }
      try await verify(token, account.id)
      onFinish(.pastedToken(token: token, account: account))
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// The account the token is for, or nil when the user now has to pick one.
  private func resolveAccount(token: String) async throws -> CloudflareAccount? {
    let explicitID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !explicitID.isEmpty {
      // Typed by hand, often because the token cannot list accounts at all. Listing is
      // tried only for a friendlier name, and its failure is not the user's problem.
      let listed = try? await listAccounts(token)
      return listed?.first { $0.id == explicitID }
        ?? CloudflareAccount(id: explicitID, name: explicitID)
    }
    if let selectedCandidateID,
      let picked = candidates.first(where: { $0.id == selectedCandidateID })
    {
      return picked
    }
    let listed = try await listAccounts(token)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    switch listed.count {
    case 0:
      throw AddAccountError.noAccount
    case 1:
      return listed[0]
    default:
      candidates = listed
      selectedCandidateID = listed[0].id
      return nil
    }
  }
}

enum AddAccountError: LocalizedError {
  case noAccount

  var errorDescription: String? {
    switch self {
    case .noAccount:
      "This token doesn't list any account. Enter the account ID, or give the token Account Settings: Read."
    }
  }
}
