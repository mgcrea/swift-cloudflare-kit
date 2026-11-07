import CloudflareKit
import SwiftUI

/// Signs in to Cloudflare again for an account whose grant expired, through the same web
/// sign-in as Add Account.
///
/// Signing in again stores the new grant under the same account, so every connection that
/// uses it recovers without being edited. A separate view rather than a pane-only button
/// because the app's own error screens need it too: that is where the user first finds out,
/// and sending them to Settings from there was the step nobody could find.
public struct CloudflareSignInAgainButton: View {
  private let accounts: CloudflareAccountStore
  private let accountID: String
  private let onSignedIn: @MainActor () -> Void

  @State private var isSigningIn = false
  @State private var failure: String?

  /// - Parameter onSignedIn: runs once the grant covers `accountID` again, e.g. to retry
  ///   whatever failed.
  public init(
    accounts: CloudflareAccountStore,
    accountID: String,
    onSignedIn: @escaping @MainActor () -> Void = {}
  ) {
    self.accounts = accounts
    self.accountID = accountID
    self.onSignedIn = onSignedIn
  }

  public var body: some View {
    Button {
      Task { await signIn() }
    } label: {
      HStack(spacing: 6) {
        Text("Sign In Again")
        if isSigningIn {
          ProgressView().controlSize(.small)
        }
      }
    }
    .disabled(isSigningIn)
    .accessibilityIdentifier("accounts.signInAgain.\(accountID)")
    .alert(
      "Couldn’t sign in again",
      isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(failure ?? "")
    }
  }

  @MainActor
  private func signIn() async {
    // Read before signing in: a sign-in that misses this account leaves it in the store, but
    // the name is what the message needs either way.
    let name = accounts.account(id: accountID)?.name ?? accountID
    isSigningIn = true
    defer { isSigningIn = false }
    do {
      let unlocked = try await accounts.signInWithWebSession()
      if let message = AccountsPaneLogic.signInAgainFailure(
        accountID: accountID, name: name, unlocked: unlocked)
      {
        failure = message
        return
      }
      onSignedIn()
    } catch CloudflareOAuthError.cancelled {
      // Closing the sheet is a choice, not a failure.
    } catch {
      failure = [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion]
        .compactMap { $0 }
        .joined(separator: " ")
    }
  }
}
