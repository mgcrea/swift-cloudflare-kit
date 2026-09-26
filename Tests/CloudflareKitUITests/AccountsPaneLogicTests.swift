import Foundation
import Testing

@testable import CloudflareKit
@testable import CloudflareKitUI

@Suite("Accounts pane")
@MainActor
struct AccountsPaneLogicTests {

  private var configuration: CloudflareOAuthConfiguration {
    makeTestStore().configuration
  }

  @Test func rows_mergeBothKindsSortedByName() {
    let rows = AccountsPaneLogic.rows(
      signedIn: [
        CloudflareAccount(
          id: "z", name: "Zeta", grantedScopes: ["d1.write", "account-analytics.read"]),
        CloudflareAccount(id: "a", name: "acme", grantedScopes: []),
      ],
      pastedTokens: [PastedTokenAccount(id: "m", name: "Middle", usedBy: 2)],
      configuration: configuration)
    #expect(rows.map(\.name) == ["acme", "Middle", "Zeta"])
    #expect(rows.map(\.id) == ["signIn:a", "token:m", "signIn:z"])
    #expect(rows[0].kind == .signedIn(declinedScopes: ["d1.write", "account-analytics.read"]))
    #expect(rows[1].kind == .pastedToken(usedBy: 2))
    #expect(rows[2].kind == .signedIn(declinedScopes: []))
  }

  /// D1 can hold a sign-in and a pasted token for the same account on different
  /// connections. Both are shown: they are removed separately.
  @Test func rows_keepASignInAndATokenForTheSameAccount() {
    let rows = AccountsPaneLogic.rows(
      signedIn: [CloudflareAccount(id: "a", name: "Acme")],
      pastedTokens: [PastedTokenAccount(id: "a", name: "Acme")],
      configuration: configuration)
    #expect(rows.map(\.id) == ["signIn:a", "token:a"])
  }

  @Test func access_fullWhenNothingWasDeclined() {
    #expect(AccountsPaneLogic.accessSummary(declinedScopes: [], scopeNouns: [:]) == "Full access")
  }

  @Test func access_namesWhatWasDeclined() {
    let nouns = ["d1.write": "editing", "account-analytics.read": "usage analytics"]
    #expect(
      AccountsPaneLogic.accessSummary(declinedScopes: ["d1.write"], scopeNouns: nouns)
        == "Connected without editing.")
    #expect(
      AccountsPaneLogic.accessSummary(
        declinedScopes: ["d1.write", "account-analytics.read"], scopeNouns: nouns)
        == "Connected without editing or usage analytics.")
  }

  @Test func access_fallsBackToTheScopeID() {
    #expect(
      AccountsPaneLogic.accessSummary(declinedScopes: ["x.write"], scopeNouns: [:])
        == "Connected without x.write.")
  }

  @Test func usedBy_inflects() {
    #expect(AccountsPaneLogic.usedBySummary(1) == "Used by 1 connection")
    #expect(AccountsPaneLogic.usedBySummary(3) == "Used by 3 connections")
  }

  /// Review Focus 5: an account whose grant is unreadable shares it with nobody.
  @Test func signOut_aloneIsAPlainConfirm() {
    #expect(
      AccountsPaneLogic.signOutMessage(name: "Acme", others: [], appName: "KVExplorer")
        == "KVExplorer won’t be able to reach Acme until you sign in again.")
  }

  /// Review Focus 5, end to end with the store: the refresh token is missing from the
  /// Keychain, so `accountsSharingGrant` can only return the account itself.
  @Test func signOut_withAMissingGrant_namesNobodyElse() {
    let store = makeTestStore()
    store.accounts = [
      CloudflareAccount(id: "a", name: "Acme"), CloudflareAccount(id: "b", name: "Beta"),
    ]
    let others = AccountsPaneLogic.otherNames(
      sharing: store.accountsSharingGrant(with: "a"), with: "a", accounts: store.accounts)
    #expect(others.isEmpty)
  }

  @Test func signOut_namesOneOther() {
    #expect(
      AccountsPaneLogic.signOutMessage(name: "Acme", others: ["Beta"], appName: "KVExplorer")
        == "Signing out of Acme also signs out of Beta, which was added in the same sign-in.")
  }

  @Test func signOut_namesTwoOthers() {
    #expect(
      AccountsPaneLogic.signOutMessage(
        name: "Acme", others: ["Gamma", "Beta"], appName: "KVExplorer")
        == "Signing out of Acme also signs out of Beta and Gamma, which were added in the same sign-in."
    )
  }

  @Test func signOut_namesSeveralOthers() {
    #expect(
      AccountsPaneLogic.signOutMessage(
        name: "Acme", others: ["Delta", "Beta", "Gamma"], appName: "KVExplorer")
        == "Signing out of Acme also signs out of Beta, Delta and Gamma, which were added in the same sign-in."
    )
  }

  /// The store's `accountsSharingGrant` includes the account itself; the pane drops it
  /// before asking for the message, and this pins that the drop is by ID, not by name.
  @Test func others_excludeTheAccountItselfByID() {
    let others = AccountsPaneLogic.otherNames(
      sharing: ["a", "b"], with: "a",
      accounts: [
        CloudflareAccount(id: "a", name: "Same"), CloudflareAccount(id: "b", name: "Same"),
      ])
    #expect(others == ["Same"])
  }
}
