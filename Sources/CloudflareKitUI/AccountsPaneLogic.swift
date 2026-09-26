import CloudflareKit
import Foundation

/// A pasted-token account as the app knows it. The pane cannot find these itself: where a
/// pasted token lives, and what uses it, is each app's own model.
public struct PastedTokenAccount: Identifiable, Equatable, Sendable {
  /// The Cloudflare account ID.
  public var id: String
  public var name: String
  /// How many connections use it, for apps that have connections (D1, R2). Nil hides the
  /// line, which is right for KVExplorer, where the account is the thing itself.
  public var usedBy: Int?

  public init(id: String, name: String, usedBy: Int? = nil) {
    self.id = id
    self.name = name
    self.usedBy = usedBy
  }
}

/// One section of the Accounts pane.
public struct AccountRow: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case signedIn(declinedScopes: [String])
    case pastedToken(usedBy: Int?)
  }

  /// Prefixed by kind, because D1 can hold a sign-in and a pasted token for the same
  /// account, and they are removed separately.
  public var id: String
  public var accountID: String
  public var name: String
  public var kind: Kind
}

/// Everything the Accounts pane decides, as plain functions.
public enum AccountsPaneLogic {

  public static func rows(
    signedIn: [CloudflareAccount],
    pastedTokens: [PastedTokenAccount],
    configuration: CloudflareOAuthConfiguration
  ) -> [AccountRow] {
    let signIns = signedIn.map { account in
      AccountRow(
        id: "signIn:\(account.id)", accountID: account.id, name: account.name,
        kind: .signedIn(declinedScopes: account.declinedScopes(against: configuration)))
    }
    let tokens = pastedTokens.map { token in
      AccountRow(
        id: "token:\(token.id)", accountID: token.id, name: token.name,
        kind: .pastedToken(usedBy: token.usedBy))
    }
    // Stable sort by name; a sign-in and a token with the same name keep sign-in first.
    return (signIns + tokens).enumerated().sorted { lhs, rhs in
      let order = lhs.element.name.localizedStandardCompare(rhs.element.name)
      return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
    }.map(\.element)
  }

  /// "Full access", or what the user declined at the consent screen, in the app's words.
  ///
  /// - Parameter scopeNouns: each optional scope's user-facing noun, e.g.
  ///   `["d1.write": "editing"]`. A scope missing from it is shown by its ID rather than
  ///   dropped, so a new scope is never silently unreported.
  public static func accessSummary(
    declinedScopes: [String], scopeNouns: [String: String]
  ) -> String {
    guard !declinedScopes.isEmpty else { return "Full access" }
    let nouns = declinedScopes.map { scopeNouns[$0] ?? $0 }
    return "Connected without \(nouns.joined(separator: " or "))."
  }

  public static func usedBySummary(_ count: Int) -> String {
    "Used by \(count) \(count == 1 ? "connection" : "connections")"
  }

  /// The confirmation shown before removing a pasted token.
  ///
  /// Removing is irreversible in a way signing out is not: Cloudflare shows a token only
  /// once, so the user cannot paste it back. Connections that use it (D1, R2) are named by
  /// count, because they stay listed but stop connecting.
  public static func removeMessage(name: String, usedBy: Int?) -> String {
    let once =
      "Cloudflare shows a token only once, so adding \(name) again means creating a new token."
    guard let usedBy, usedBy > 0 else { return once }
    let subject = usedBy == 1 ? "1 connection uses" : "\(usedBy) connections use"
    return "\(subject) this token and won’t connect until you add one again. \(once)"
  }

  /// The names of every other account a sign-out takes with it.
  public static func otherNames(
    sharing ids: [String], with accountID: String, accounts: [CloudflareAccount]
  ) -> [String] {
    ids.filter { $0 != accountID }.compactMap { id in accounts.first { $0.id == id }?.name }
  }

  /// The confirmation shown before signing out.
  ///
  /// Signing out revokes the whole grant, so every account from the same sign-in goes too.
  /// Naming them is what stops someone losing three accounts while expecting to lose one.
  public static func signOutMessage(name: String, others: [String], appName: String) -> String {
    guard !others.isEmpty else {
      return "\(appName) won’t be able to reach \(name) until you sign in again."
    }
    let sorted = others.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let list: String
    if sorted.count == 1 {
      list = sorted[0]
    } else {
      list = sorted.dropLast().joined(separator: ", ") + " and " + sorted[sorted.count - 1]
    }
    let verb = sorted.count == 1 ? "was" : "were"
    return
      "Signing out of \(name) also signs out of \(list), which \(verb) added in the same sign-in."
  }
}
