import Foundation
import Testing

@testable import CloudflareKit
@testable import CloudflareKitUI

/// Everything the add-account sections decide, driven without a view, a network or a
/// browser. Each dependency is a closure the test replaces.
@Suite("Add account")
@MainActor
struct AddAccountModelTests {

  final class Recorder: @unchecked Sendable {
    var finished: [AddAccountResult] = []
    var demoEntered = 0
    var listedWith: [String] = []
    var verified: [(String, String)] = []
  }

  private let acme = CloudflareAccount(id: "a1", name: "Acme")
  private let beta = CloudflareAccount(id: "b2", name: "Beta")

  private func makeModel(
    recorder: Recorder,
    signIn: (@MainActor () async throws -> [CloudflareAccount])? = nil,
    accounts: [CloudflareAccount] = [],
    listFails: Bool = false,
    verifyFails: Bool = false,
    demo: Bool = true
  ) -> AddAccountModel {
    // Typed one at a time: inferring all five closures in one call crashes the Swift 6.4
    // type checker ("failed to produce diagnostic for expression").
    let listAccounts: @Sendable (String) async throws -> [CloudflareAccount] = { token in
      recorder.listedWith.append(token)
      if listFails { throw CloudflareAccountsError.http(status: 403, message: "") }
      return accounts
    }
    let verify: @Sendable (String, String) async throws -> Void = { token, id in
      recorder.verified.append((token, id))
      if verifyFails { throw URLError(.userAuthenticationRequired) }
    }
    let enterDemo: @MainActor () -> Void = { recorder.demoEntered += 1 }
    let finish: @MainActor (AddAccountResult) -> Void = { recorder.finished.append($0) }
    return AddAccountModel(
      signIn: signIn,
      listAccounts: listAccounts,
      verify: verify,
      onReviewDemo: demo ? enterDemo : nil,
      onFinish: finish)
  }

  // MARK: Review demo

  @Test func theTrigger_entersTheDemoWithoutValidating() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder)
    model.token = " AppReview-Demo "
    await model.addToken()
    #expect(recorder.demoEntered == 1)
    #expect(recorder.listedWith.isEmpty)
    #expect(model.token == "")
    #expect(recorder.finished.isEmpty)
  }

  @Test func theTrigger_insideTheDemo_isJustABadToken() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [], demo: false)
    model.token = "appreview-demo"
    await model.addToken()
    #expect(recorder.demoEntered == 0)
    #expect(recorder.listedWith == ["appreview-demo"])
  }

  // MARK: Pasted token

  @Test func anEmptyToken_saysSo() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder)
    model.token = "   "
    await model.addToken()
    #expect(model.error == "Paste an API token first.")
    #expect(recorder.listedWith.isEmpty)
  }

  @Test func aTokenForOneAccount_isVerifiedAndAdded() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [acme])
    model.token = "  tok\n"
    await model.addToken()
    #expect(recorder.listedWith == ["tok"])
    #expect(recorder.verified.map(\.0) == ["tok"])
    #expect(recorder.verified.map(\.1) == ["a1"])
    #expect(recorder.finished == [.pastedToken(token: "tok", account: acme)])
  }

  @Test func aTokenForNoAccount_asksForTheID() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [])
    model.token = "tok"
    await model.addToken()
    #expect(model.error?.contains("Account Settings: Read") == true)
    #expect(recorder.finished.isEmpty)
  }

  @Test func aTokenForSeveralAccounts_offersAPickSortedByName() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [beta, acme])
    model.token = "tok"
    await model.addToken()
    #expect(model.candidates == [acme, beta])
    #expect(model.selectedCandidateID == "a1")
    #expect(recorder.verified.isEmpty)
    #expect(recorder.finished.isEmpty)

    model.selectedCandidateID = "b2"
    await model.addToken()
    #expect(recorder.listedWith == ["tok"])
    #expect(recorder.finished == [.pastedToken(token: "tok", account: beta)])
  }

  /// Review Focus 2: a pick made for one token must never be applied to another.
  @Test func editingTheToken_dropsThePick() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [beta, acme])
    model.token = "tok"
    await model.addToken()
    #expect(!model.candidates.isEmpty)

    model.token = "other"
    model.tokenDidChange()
    #expect(model.candidates.isEmpty)
    #expect(model.selectedCandidateID == nil)
  }

  /// Review Focus 4: a token without Account Settings: Read cannot list accounts, and the
  /// user typed the ID for exactly that reason.
  @Test func anExplicitID_survivesAListingFailure() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, listFails: true)
    model.token = "tok"
    model.accountID = " a9 "
    await model.addToken()
    #expect(recorder.verified.map(\.1) == ["a9"])
    #expect(recorder.finished == [.pastedToken(token: "tok", account: .init(id: "a9", name: "a9"))])
  }

  @Test func anExplicitID_takesItsNameFromTheListingWhenItCan() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [acme, beta])
    model.token = "tok"
    model.accountID = "b2"
    await model.addToken()
    #expect(recorder.finished == [.pastedToken(token: "tok", account: beta)])
  }

  @Test func aVerifyFailure_isShownAndNothingIsAdded() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [acme], verifyFails: true)
    model.token = "tok"
    await model.addToken()
    #expect(model.error != nil)
    #expect(recorder.finished.isEmpty)
    #expect(model.isAdding == false)
  }

  @Test func aListingFailure_withoutAnID_isShown() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, listFails: true)
    model.token = "tok"
    await model.addToken()
    #expect(model.error != nil)
    #expect(recorder.finished.isEmpty)
  }

  // MARK: Sign in

  @Test func signIn_reportsEveryAccountTheGrantUnlocked() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, signIn: { [acme, beta] })
    await model.signIn()
    #expect(recorder.finished == [.signedIn([acme, beta])])
    #expect(model.isSigningIn == false)
  }

  @Test func aCancelledSignIn_isSilent() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, signIn: { throw CloudflareOAuthError.cancelled })
    await model.signIn()
    #expect(model.error == nil)
    #expect(recorder.finished.isEmpty)
  }

  @Test func aFailedSignIn_isShown() async {
    let recorder = Recorder()
    let model = makeModel(
      recorder: recorder,
      signIn: { throw CloudflareWebSignInError.domainNotAssociated("example.test") })
    await model.signIn()
    #expect(
      model.error == "This build isn't allowed to receive the sign-in redirect from example.test.")
  }

  @Test func withoutAStore_signInIsHidden() {
    let model = makeModel(recorder: Recorder(), signIn: nil)
    #expect(model.canSignIn == false)
  }

  @Test func theSignInTitle_followsTheState() {
    let model = makeModel(recorder: Recorder(), signIn: { [] })
    #expect(model.signInTitle == "Sign in with Cloudflare")
    model.hasSignedInBefore = true
    #expect(model.signInTitle == "Sign in to Another Account…")
    model.isSigningIn = true
    #expect(model.signInTitle == "Waiting for Cloudflare…")
  }

  // MARK: Re-entrancy (Review Focus 3)

  @Test func aSecondAdd_whileOneRuns_isIgnored() async {
    let recorder = Recorder()
    let model = makeModel(recorder: recorder, accounts: [acme])
    model.token = "tok"
    model.isAdding = true
    await model.addToken()
    #expect(recorder.listedWith.isEmpty)
  }

  @Test func aSecondSignIn_whileOneRuns_isIgnored() async {
    let recorder = Recorder()
    var calls = 0
    let model = makeModel(
      recorder: recorder,
      signIn: {
        calls += 1
        return []
      })
    model.isSigningIn = true
    await model.signIn()
    #expect(calls == 0)
  }
}
