import Foundation
import Testing

@testable import CloudflareKit

/// Redirect handling, tested without binding a port.
@Suite("Loopback redirect parsing")
struct LoopbackRedirectParserTests {

  @Test func queryItems_readsAWellFormedRequestLine() throws {
    let items = try #require(
      LoopbackRedirectParser.queryItems(
        requestLine: "GET /callback?code=abc&state=xyz HTTP/1.1"))

    #expect(items["code"] == "abc")
    #expect(items["state"] == "xyz")
  }

  /// A port scanner or a stray `curl` reaches this socket too. Anything that is not a GET
  /// request line must not be mistaken for a redirect, or unrelated traffic would fail a
  /// sign-in that is still in progress.
  @Test func queryItems_rejectsAnythingThatIsNotAGETRequestLine() {
    #expect(LoopbackRedirectParser.queryItems(requestLine: "") == nil)
    #expect(LoopbackRedirectParser.queryItems(requestLine: "garbage") == nil)
    #expect(LoopbackRedirectParser.queryItems(requestLine: "POST /callback HTTP/1.1") == nil)
  }

  /// The `state` check is the whole defence against an attacker getting their own
  /// authorization code adopted: anyone can reach a loopback port on this machine, so an
  /// unverified `code` is not evidence of anything.
  @Test func outcome_rejectsAMismatchedState() {
    let result = LoopbackRedirectParser.outcome(
      query: ["code": "abc", "state": "wrong"], expectedState: "right")

    #expect(result == .failure(.stateMismatch))
  }

  @Test func outcome_rejectsAMissingState() {
    #expect(
      LoopbackRedirectParser.outcome(query: ["code": "abc"], expectedState: "right")
        == .failure(.stateMismatch))
  }

  @Test func outcome_returnsTheCodeWhenTheStateMatches() {
    #expect(
      LoopbackRedirectParser.outcome(
        query: ["code": "abc", "state": "right"], expectedState: "right") == .success("abc"))
  }

  /// The user pressed Cancel on the consent screen. Not a failure to report as one.
  @Test func outcome_readsAccessDeniedAsACancellation() {
    #expect(
      LoopbackRedirectParser.outcome(query: ["error": "access_denied"], expectedState: "s")
        == .failure(.cancelled))
  }

  /// An error is checked before the state, because Cloudflare does not always echo state
  /// on an error and reporting "rejected as hostile" would bury the real reason.
  @Test func outcome_keepsTheServerErrorDetail() {
    #expect(
      LoopbackRedirectParser.outcome(
        query: ["error": "invalid_scope", "error_description": "nope"], expectedState: "s")
        == .failure(.server(status: 400, code: "invalid_scope", message: "nope")))
  }

  @Test func outcome_rejectsAnEmptyCode() {
    #expect(
      LoopbackRedirectParser.outcome(
        query: ["code": "", "state": "right"], expectedState: "right")
        == .failure(.invalidResponse))
  }

  @Test func constantTimeEquals_matchesOnlyIdenticalStrings() {
    #expect(LoopbackRedirectParser.constantTimeEquals("abc", "abc"))
    #expect(!LoopbackRedirectParser.constantTimeEquals("abc", "abd"))
    #expect(!LoopbackRedirectParser.constantTimeEquals("abc", "abcd"))
    #expect(LoopbackRedirectParser.constantTimeEquals("", ""))
  }

  /// The page renders in the user's browser, so any external reference would be a request
  /// the app caused off Cloudflare — quietly making a consumer's App Store privacy label
  /// wrong. A single `<img>` added here would not otherwise be noticed.
  @Test func responseBody_referencesNothingOffDevice() {
    for success in [true, false] {
      let body = LoopbackRedirectParser.responseBody(success: success, appName: "TestApp")
      for reference in ["http://", "https://", "//", "<img", "<script", "<link", "@import"] {
        #expect(!body.contains(reference), "\(reference) must not appear in the page")
      }
    }
  }

  /// The user is looking at a browser, not at the app, so the page has to say which app to
  /// go back to. This is the one string that genuinely needs the app's name.
  @Test func responseBody_namesTheAppSoTheUserKnowsWhereToReturn() {
    let body = LoopbackRedirectParser.responseBody(success: true, appName: "TestApp")

    #expect(body.contains("return to TestApp"))
    #expect(body.contains("<title>TestApp</title>"))
  }

  /// A wrong `Content-Length` leaves the browser hanging on a half-read response, which
  /// looks to the user like a sign-in that never finished.
  @Test func httpResponse_declaresTheByteCountOfTheBody() throws {
    let data = LoopbackRedirectParser.httpResponse(success: true, appName: "TestApp")
    let text = try #require(String(data: data, encoding: .utf8))
    let body = LoopbackRedirectParser.responseBody(success: true, appName: "TestApp")

    #expect(text.contains("Content-Length: \(Data(body.utf8).count)"))
    #expect(text.hasPrefix("HTTP/1.1 200 OK"))
  }
  // MARK: - Callback URLs handed over whole

  @Test func queryItems_readsAnHTTPSCallbackURL() throws {
    let items = try #require(
      LoopbackRedirectParser.queryItems(
        callbackURL: URL(string: "https://almanac.mgcrea.io/oauth/callback?code=abc&state=xyz")!))
    #expect(items["code"] == "abc")
    #expect(items["state"] == "xyz")
  }

  @Test func queryItems_readsAnErrorFromACallbackURL() throws {
    let items = try #require(
      LoopbackRedirectParser.queryItems(
        callbackURL: URL(string: "https://almanac.mgcrea.io/oauth/callback?error=access_denied")!))
    #expect(
      LoopbackRedirectParser.outcome(query: items, expectedState: "xyz")
        == .failure(.cancelled))
  }

  /// The point of sharing `outcome` between the two transports: a callback that arrived
  /// through `ASWebAuthenticationSession` is no more trusted than one off a socket. The OS
  /// vouches that the app may receive the host, not that this is the response we asked for.
  @Test func callbackURL_withTheWrongStateIsRejected() throws {
    let items = try #require(
      LoopbackRedirectParser.queryItems(
        callbackURL: URL(string: "https://almanac.mgcrea.io/oauth/callback?code=abc&state=attacker")!))
    #expect(
      LoopbackRedirectParser.outcome(query: items, expectedState: "xyz")
        == .failure(.stateMismatch))
  }

  @Test func queryItems_readsNoParametersFromABareCallbackURL() throws {
    let items = try #require(
      LoopbackRedirectParser.queryItems(
        callbackURL: URL(string: "https://almanac.mgcrea.io/oauth/callback")!))
    #expect(items.isEmpty)
    #expect(
      LoopbackRedirectParser.outcome(query: items, expectedState: "xyz")
        == .failure(.stateMismatch))
  }

  // MARK: - The registered https redirect

  @Test func httpsCallback_buildsTheRegisteredRedirectURI() {
    let callback = CloudflareOAuthConfiguration.HTTPSCallback(
      host: "almanac.mgcrea.io", path: "/oauth/callback")
    #expect(callback.redirectURI == "https://almanac.mgcrea.io/oauth/callback")
  }

}
