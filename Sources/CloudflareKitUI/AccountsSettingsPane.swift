import CloudflareKit
import SwiftUI

/// Settings › Accounts, the same in every app: sign-in and pasted-token accounts together,
/// each with the one way to remove it, and a button to add another.
///
/// Adding is the app's sheet (`addAccount`), not a sign-in button here: D1 needs its
/// database step after the account, and the sheet should look the same wherever it opens.
public struct AccountsSettingsPane: View {
  private let accounts: CloudflareAccountStore?
  private let pastedTokens: [PastedTokenAccount]
  private let scopeNouns: [String: String]
  private let removePastedToken: @MainActor (String) async -> Void
  private let addAccount: @MainActor () -> Void
  private let isDemo: Bool

  @Environment(\.openURL) private var openURL
  @State private var pendingSignOut: AccountRow?
  @State private var pendingRemoval: AccountRow?
  @State private var busyRowID: String?
  @State private var error: String?

  /// - Parameter scopeNouns: the user-facing noun for each optional scope, e.g.
  ///   `["workers-kv-storage.write": "write access"]`.
  /// - Parameter isDemo: disables every change; the demo's accounts are shown read-only.
  public init(
    accounts: CloudflareAccountStore?,
    pastedTokens: [PastedTokenAccount],
    scopeNouns: [String: String],
    removePastedToken: @escaping @MainActor (String) async -> Void,
    addAccount: @escaping @MainActor () -> Void,
    isDemo: Bool
  ) {
    self.accounts = accounts
    self.pastedTokens = pastedTokens
    self.scopeNouns = scopeNouns
    self.removePastedToken = removePastedToken
    self.addAccount = addAccount
    self.isDemo = isDemo
  }

  private var rows: [AccountRow] {
    guard let accounts else {
      return AccountsPaneLogic.rows(
        signedIn: [], pastedTokens: pastedTokens, configuration: .placeholder)
    }
    return AccountsPaneLogic.rows(
      signedIn: accounts.accounts, pastedTokens: pastedTokens,
      configuration: accounts.configuration)
  }

  public var body: some View {
    Form {
      if rows.isEmpty {
        Section {
          Text("No Cloudflare accounts yet.")
            .foregroundStyle(.secondary)
        }
      }

      ForEach(rows) { row in
        Section(row.name) {
          LabeledContent("Account ID") {
            Text(row.accountID)
              .font(.body.monospaced())
              .textSelection(.enabled)
          }
          kindLine(row)
          buttons(row)
        }
      }

      Section {
        Button("Add Account…", action: addAccount)
          .disabled(isDemo)
          .accessibilityIdentifier("accounts.add")
      }

      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
          Button("Manage on Cloudflare…") { openURL(CloudflareOAuth.connectedApplications) }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Sign out of \(pendingSignOut?.name ?? "")?",
      isPresented: Binding(
        get: { pendingSignOut != nil }, set: { if !$0 { pendingSignOut = nil } }),
      titleVisibility: .visible,
      presenting: pendingSignOut
    ) { row in
      Button("Sign Out", role: .destructive) { Task { await signOut(row) } }
    } message: { row in
      Text(signOutMessage(row))
    }
    .confirmationDialog(
      "Remove the API token for \(pendingRemoval?.name ?? "")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { row in
      Button("Remove", role: .destructive) { Task { await remove(row) } }
    } message: { row in
      Text(AccountsPaneLogic.removeMessage(name: row.name, usedBy: usedBy(row)))
    }
  }

  @ViewBuilder
  private func kindLine(_ row: AccountRow) -> some View {
    switch row.kind {
    case .signedIn(let declined):
      Label(
        "Signed in with Cloudflare · "
          + AccountsPaneLogic.accessSummary(declinedScopes: declined, scopeNouns: scopeNouns),
        systemImage: declined.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
      )
      // Orange, not red: the user chose this at the consent screen, and it works.
      .foregroundStyle(declined.isEmpty ? Color.secondary : Color.orange)
    case .pastedToken(let usedBy):
      Label("API token", systemImage: "key")
        .foregroundStyle(.secondary)
      if let usedBy {
        Text(AccountsPaneLogic.usedBySummary(usedBy))
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func buttons(_ row: AccountRow) -> some View {
    HStack {
      switch row.kind {
      case .signedIn:
        Button("Sign Out", role: .destructive) { pendingSignOut = row }
          .accessibilityIdentifier("accounts.signOut.\(row.accountID)")
        // Beside Sign Out because revoking is the user's to do directly, not only
        // something this app can do on their behalf.
        Button("Manage on Cloudflare…") { openURL(CloudflareOAuth.connectedApplications) }
      case .pastedToken:
        Button("Remove", role: .destructive) { pendingRemoval = row }
          .accessibilityIdentifier("accounts.remove.\(row.accountID)")
      }
      if busyRowID == row.id {
        ProgressView().controlSize(.small)
      }
    }
    .disabled(isDemo || busyRowID != nil)
  }

  private func usedBy(_ row: AccountRow) -> Int? {
    if case .pastedToken(let usedBy) = row.kind { usedBy } else { nil }
  }

  private func remove(_ row: AccountRow) async {
    busyRowID = row.id
    defer { busyRowID = nil }
    await removePastedToken(row.accountID)
  }

  private func signOutMessage(_ row: AccountRow) -> String {
    guard let accounts else { return "" }
    let others = AccountsPaneLogic.otherNames(
      sharing: accounts.accountsSharingGrant(with: row.accountID), with: row.accountID,
      accounts: accounts.accounts)
    return AccountsPaneLogic.signOutMessage(
      name: row.name, others: others, appName: accounts.configuration.appName)
  }

  private func signOut(_ row: AccountRow) async {
    guard let accounts else { return }
    error = nil
    busyRowID = row.id
    defer { busyRowID = nil }
    do {
      try await accounts.signOut(accountID: row.accountID)
    } catch {
      // The grant is always cleared locally, so the user is signed out here even when the
      // revoke call fails. Say what is left undone rather than implying nothing happened.
      self.error =
        "Signed out on this device, but Cloudflare could not be told to revoke the grant. Remove it from Connected Applications to finish."
    }
  }
}

extension CloudflareOAuthConfiguration {
  /// Only for listing pasted tokens when the app has no account store: no row reads its
  /// scopes, since pasted-token rows have none.
  fileprivate static let placeholder = CloudflareOAuthConfiguration(
    clientID: "", appName: "", requiredScopes: [], optionalScopes: [], redirectPorts: [],
    loggingSubsystem: "io.mgcrea.CloudflareKitUI")
}
