import AuthenticationServices
import Foundation
import Testing

@testable import CloudflareKit
@testable import CloudflareKitUI

@Suite("Review demo trigger")
struct CloudflareReviewDemoTests {
  @Test(arguments: ["appreview-demo", "  appreview-demo\n", "AppReview-Demo"])
  func matches(_ text: String) {
    #expect(CloudflareReviewDemo.isTrigger(text))
  }

  @Test(arguments: ["", "appreview", "appreview-demo2", "app review-demo", "demo"])
  func ignoresNearMisses(_ text: String) {
    #expect(!CloudflareReviewDemo.isTrigger(text))
  }
}

@Suite("In-app sign-in")
@MainActor
struct CloudflareWebSignInTests {

  private func sessionError(reason: String?) -> NSError {
    var info: [String: Any] = [:]
    if let reason { info[NSLocalizedFailureReasonErrorKey] = reason }
    return NSError(
      domain: ASWebAuthenticationSessionError.errorDomain,
      code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue,
      userInfo: info)
  }

  @Test func aPlainCancel_isACancel() {
    let error = CloudflareWebSignIn.classify(sessionError(reason: nil), host: "example.test")
    #expect(error as? CloudflareOAuthError == .cancelled)
  }

  /// `canceledLogin` is also what an unverifiable callback host reports. Told apart by the
  /// failure reason, because a broken association file must not look like every user
  /// changing their mind.
  @Test func anUnassociatedHost_isNamed() {
    let error = CloudflareWebSignIn.classify(
      sessionError(reason: "The callback host is not associated with domain example.test"),
      host: "example.test")
    #expect(
      error as? CloudflareWebSignInError == .domainNotAssociated("example.test"))
  }

  @Test func anotherError_passesThrough() {
    let other = URLError(.notConnectedToInternet)
    let error = CloudflareWebSignIn.classify(other, host: "example.test")
    #expect((error as? URLError)?.code == .notConnectedToInternet)
  }

  @Test func noErrorAndNoURL_couldNotStart() {
    let error = CloudflareWebSignIn.classify(nil, host: "example.test")
    #expect(error as? CloudflareWebSignInError == .couldNotStart)
  }

  /// Falling back to the loopback flow here would put an app back in the default browser,
  /// which is what App Review rejected. A missing callback is a setup error, said so.
  @Test func withoutAnHTTPSCallback_signInRefusesToFallBack() async {
    let store = makeTestStore(httpsCallback: nil)
    await #expect(throws: CloudflareWebSignInError.noHTTPSCallback) {
      try await store.signInWithWebSession()
    }
  }
}

/// Not `@MainActor`, unlike the suite above: the point is to call from elsewhere.
@Suite("In-app sign-in callback")
struct CloudflareWebSignInCallbackTests {
  /// `ASWebAuthenticationSession` calls its handler on an XPC reply queue, not the main
  /// thread. A handler inferred `@MainActor` traps there in Swift 6 mode, which is what
  /// KVExplorer build 54 did on its first sign-in.
  @Test func aCallbackURL_isDeliveredFromAnyQueue() async throws {
    let url = URL(string: "https://example.test/oauth/callback?code=abc")!
    let received = try await withCheckedThrowingContinuation { continuation in
      let completion = CloudflareWebSignIn.completion(
        host: "example.test", continuation: continuation)
      DispatchQueue.global().async { completion(url, nil) }
    }
    #expect(received == url)
  }

  @Test func anError_isClassifiedFromAnyQueue() async {
    let cancel = NSError(
      domain: ASWebAuthenticationSessionError.errorDomain,
      code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue)
    await #expect(throws: CloudflareOAuthError.cancelled) {
      try await withCheckedThrowingContinuation { continuation in
        let completion = CloudflareWebSignIn.completion(
          host: "example.test", continuation: continuation)
        DispatchQueue.global().async { completion(nil, cancel) }
      }
    }
  }
}
