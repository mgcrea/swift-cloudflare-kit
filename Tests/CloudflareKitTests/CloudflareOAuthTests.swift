import Foundation
import Testing

@testable import CloudflareKit

/// The OAuth flow, ported from the two copies that used to live in D1Explorer and
/// R2Explorer. Where they disagreed, the reconciled behaviour is pinned here.
@Suite("Cloudflare OAuth")
struct CloudflareOAuthTests {

  /// A stand-in registration. Deliberately not either shipping app's client id.
  static let configuration = CloudflareOAuthConfiguration(
    clientID: "test-client-id",
    appName: "TestApp",
    requiredScopes: ["d1.read", "account-settings.read"],
    optionalScopes: ["d1.write", "account-analytics.read"],
    redirectPorts: [53682, 53683],
    loggingSubsystem: "io.mgcrea.CloudflareKitTests")

  private var oauth: CloudflareOAuth { CloudflareOAuth(configuration: Self.configuration) }

  // MARK: - PKCE

  /// RFC 7636 Appendix B's worked example. Pinning the published vector rather than a
  /// self-generated pair is the point: a base64url bug that mangled both the verifier and
  /// the challenge identically would pass a round-trip test and fail against Cloudflare.
  @Test func pkce_challengeMatchesTheRFC7636Vector() {
    let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  /// 0xFB 0xFF encodes to "+/8=" in standard base64 — one character from each of the two
  /// substitutions plus padding, so this single input exercises all three rules.
  @Test func pkce_base64URLHasNoPaddingOrUnsafeCharacters() {
    #expect(PKCE.base64URL(Data([0xFB, 0xFF])) == "-_8")
  }

  @Test func pkce_generatedVerifierIsWithinTheRFCLengthRange() {
    let verifier = PKCE().verifier
    #expect(verifier.count >= 43)
    #expect(verifier.count <= 128)
  }

  @Test func pkce_generatedVerifiersDiffer() {
    #expect(PKCE().verifier != PKCE().verifier)
  }

  /// Cloudflare rejects a state shorter than 8 characters — verified against the live
  /// authorize endpoint, which answered `invalid_state` for a short one.
  @Test func pkce_stateIsLongEnoughForCloudflare() {
    #expect(PKCE.makeState().count >= 8)
    #expect(PKCE.makeState() != PKCE.makeState())
  }

  // MARK: - Authorization URL

  @Test func authorizationURL_carriesEveryRequiredParameter() throws {
    let url = oauth.authorizationURL(
      state: "state-value",
      challenge: "challenge-value",
      redirectURI: "http://127.0.0.1:53682/callback",
      scopes: ["d1.read", "d1.write"])
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    var items: [String: String] = [:]
    for item in components.queryItems ?? [] { items[item.name] = item.value }

    #expect(components.host == "dash.cloudflare.com")
    #expect(components.path == "/oauth2/auth")
    #expect(items["response_type"] == "code")
    #expect(items["client_id"] == "test-client-id")
    #expect(items["redirect_uri"] == "http://127.0.0.1:53682/callback")
    #expect(items["state"] == "state-value")
    #expect(items["code_challenge"] == "challenge-value")
    #expect(items["code_challenge_method"] == "S256")
    #expect(items["scope"] == "d1.read d1.write")
  }

  /// Omitting `offline_access` yields an access token with no refresh token, the grant
  /// dies at the first expiry, and the user is bounced back to the browser mid-session.
  /// Registering `refresh_token` in `grant_types` only makes the scope *available*.
  @Test func authorizationURL_alwaysAsksForOfflineAccess() throws {
    let url = oauth.authorizationURL(
      state: "s", challenge: "c", redirectURI: "http://127.0.0.1:53682/callback")
    let scope = try #require(
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "scope" }?.value)

    #expect(scope.contains("offline_access"))
  }

  /// A public client has no secret, and a `client_secret` reaching the wire would be a
  /// leaked credential in a shipped binary.
  @Test func authorizationURL_carriesNoClientSecret() {
    let url = oauth.authorizationURL(
      state: "s", challenge: "c", redirectURI: "http://127.0.0.1:53682/callback")

    #expect(!url.absoluteString.contains("client_secret"))
  }

  // MARK: - Form encoding

  /// `.urlQueryAllowed` permits `+` and `&`, which are structural in a form body: a
  /// verifier containing either would silently split into extra fields.
  @Test func formEncode_escapesCharactersThatWouldSplitTheBody() {
    let encoded = CloudflareOAuth.formEncode(["code": "a+b&c=d", "client_id": "x"])

    #expect(encoded == "client_id=x&code=a%2Bb%26c%3Dd")
  }

  // MARK: - Token response

  /// A refresh response is not obliged to reissue a refresh token; when it is absent the
  /// previously stored one stays valid. Dropping it on a nil signs the user out at the
  /// next expiry.
  @Test func tokenResponse_toleratesAMissingRefreshToken() throws {
    let body = Data(#"{"access_token":"a","expires_in":3600,"scope":"d1.read"}"#.utf8)
    let decoded = try JSONDecoder().decode(CloudflareOAuth.TokenResponse.self, from: body)

    #expect(decoded.refreshToken == nil)
    #expect(decoded.grantedScopes == ["d1.read"])
  }

  /// `scope` is what was *granted*, not what was asked for — the only place an app can
  /// learn that the user declined an optional scope.
  @Test func tokenResponse_reportsTheGrantedScopesNotTheRequestedOnes() throws {
    let body = Data(
      #"{"access_token":"a","expires_in":3600,"refresh_token":"r","scope":"d1.read offline_access"}"#
        .utf8)
    let decoded = try JSONDecoder().decode(CloudflareOAuth.TokenResponse.self, from: body)

    #expect(decoded.grantedScopes == ["d1.read", "offline_access"])
    #expect(!decoded.grantedScopes.contains("d1.write"))
  }

  /// Cloudflare publishes no fixed access-token lifetime and it is theirs to change, so
  /// `expires_in` is the only trustworthy source.
  @Test func tokenResponse_derivesExpiryFromExpiresIn() throws {
    let body = Data(#"{"access_token":"a","expires_in":3600}"#.utf8)
    let decoded = try JSONDecoder().decode(CloudflareOAuth.TokenResponse.self, from: body)

    #expect(decoded.expiry.timeIntervalSinceNow > 3500)
    #expect(decoded.expiry.timeIntervalSinceNow <= 3600)
  }

  // MARK: - Error decoding

  /// `invalid_grant` means the refresh token is spent or the grant was revoked from the
  /// dashboard. The fix is to sign in again, not to retry, so it gets its own case.
  @Test func decodeError_namesAnExpiredGrant() {
    let body = Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8)

    #expect(CloudflareOAuth.decodeError(data: body, status: 400) == .grantExpired)
  }

  @Test func decodeError_keepsTheServerDetailForAnythingElse() {
    let body = Data(#"{"error":"invalid_scope","error_description":"bad scope"}"#.utf8)

    #expect(
      CloudflareOAuth.decodeError(data: body, status: 400)
        == .server(status: 400, code: "invalid_scope", message: "bad scope"))
  }

  /// These endpoints are on the dashboard, not the API, so the body is RFC 6749 §5.2 and
  /// not Cloudflare's `{ success, errors[] }` shape. An unparseable body must still
  /// surface something a human can act on.
  @Test func decodeError_survivesABodyThatIsNotTheOAuthEnvelope() {
    let error = CloudflareOAuth.decodeError(data: Data("gateway timeout".utf8), status: 504)

    #expect(error == .server(status: 504, code: nil, message: "gateway timeout"))
  }

  // MARK: - Configuration

  /// `offline_access` is protocol plumbing and is deliberately kept out of
  /// `requiredScopes`, which drives consent copy and the declined-scope comparison.
  @Test func configuration_appendsOfflineAccessWithoutPollutingRequiredScopes() {
    #expect(!Self.configuration.requiredScopes.contains("offline_access"))
    #expect(Self.configuration.allScopes.last == "offline_access")
  }

  @Test func configuration_buildsALoopbackRedirectURI() {
    #expect(Self.configuration.redirectURI(port: 53682) == "http://127.0.0.1:53682/callback")
  }
}
