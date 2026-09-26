import CloudflareKit
import SwiftUI

/// The account part of an add sheet, identical in every app: "Sign in with Cloudflare",
/// and a pasted API token as the fallback.
///
/// Renders sections, not a `Form`, so an app places it inside its own sheet's `Form`:
/// KVExplorer and R2Explorer finish on it, D1Explorer adds its database picker after it.
public struct AddAccountForm: View {
  @State private var model: AddAccountModel
  @State private var showsToken: Bool
  private let tokenHint: String

  /// - Parameter tokenHint: the permission this app's token needs, in the user's words,
  ///   e.g. "The token needs Workers KV Storage: Read."
  public init(
    accounts: CloudflareAccountStore?,
    tokenHint: String,
    verify: @escaping @Sendable (String, String) async throws -> Void,
    onReviewDemo: (@MainActor () -> Void)?,
    onFinish: @escaping @MainActor (AddAccountResult) -> Void
  ) {
    let model = AddAccountModel(
      accounts: accounts, verify: verify, onReviewDemo: onReviewDemo, onFinish: onFinish)
    _model = State(initialValue: model)
    // Open when there is nothing else to use, folded behind sign-in otherwise.
    _showsToken = State(initialValue: !model.canSignIn)
    self.tokenHint = tokenHint
  }

  public var body: some View {
    if model.canSignIn {
      Section {
        Button {
          Task { await model.signIn() }
        } label: {
          HStack(spacing: 6) {
            Label(model.signInTitle, systemImage: "person.badge.key")
            if model.isSigningIn {
              Spacer()
              ProgressView().controlSize(.small)
            }
          }
        }
        .disabled(model.isSigningIn || model.isAdding)
        .accessibilityIdentifier("addAccount.signIn")
      } footer: {
        Text(
          "Opens Cloudflare’s sign-in page. You choose what to allow, and can withdraw it from your Cloudflare profile at any time."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }

    Section {
      DisclosureGroup("Use an API token", isExpanded: $showsToken) {
        SecureField("API token", text: $model.token)
          .accessibilityIdentifier("addAccount.token")
          .onSubmit { Task { await model.addToken() } }
          .onChange(of: model.token) { model.tokenDidChange() }
        if model.candidates.isEmpty {
          TextField("Account ID (optional)", text: $model.accountID)
            .accessibilityIdentifier("addAccount.accountID")
            .onSubmit { Task { await model.addToken() } }
        } else {
          Picker("Account", selection: $model.selectedCandidateID) {
            ForEach(model.candidates) { account in
              Text(account.name).tag(Optional(account.id))
            }
          }
          .accessibilityIdentifier("addAccount.account")
        }
        HStack {
          Spacer()
          if model.isAdding {
            ProgressView().controlSize(.small)
          }
          Button("Add") { Task { await model.addToken() } }
            .disabled(model.isAdding || model.isSigningIn)
            .accessibilityIdentifier("addAccount.addToken")
        }
      }
      .accessibilityIdentifier("addAccount.tokenGroup")
    } footer: {
      Text(
        "\(tokenHint) Leave the account ID empty to use the token’s own account; that also needs Account Settings: Read."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }

    if let error = model.error {
      Section {
        Label(error, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .accessibilityIdentifier("addAccount.error")
      }
    }
  }
}
