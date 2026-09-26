# CloudflareKit account UI (1.5.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give swift-cloudflare-kit one shared way to add, list and remove Cloudflare accounts, so KVExplorer, D1Explorer and R2Explorer manage accounts identically and all sign in in-app on the Mac.

**Architecture:** `CloudflareKit` gains `CloudflareCredential` (the pasted-token-or-sign-in enum D1 and R2 already persist) and a public `configuration` on the store. A new `CloudflareKitUI` product holds the `ASWebAuthenticationSession` presenter, the add-account sections and the Accounts settings pane. Every decision lives in a plain type (`AddAccountModel`, `AccountsPaneLogic`, `CloudflareWebSignIn.classify`) with unit tests; the SwiftUI views are thin and only build-checked on both platforms.

**Tech Stack:** Swift 6 (tools 6.0, strict concurrency), SwiftUI, Observation, AuthenticationServices, Swift Testing (`import Testing`), SwiftPM. Formatter: `xcrun swift-format` with the repo's `.swift-format` (2 spaces, 100 columns).

**Spec:** `docs/superpowers/specs/2026-09-26-account-management-ui-design.md` (read it first; this plan implements its section 1 only).

## Global Constraints

- Platform floor stays `.macOS(.v15), .iOS(.v17)`. The https callback API is `@available(iOS 17.4, *)`; anything below throws `CloudflareWebSignInError.unavailable`.
- `CloudflareKit` stays UI-free: no SwiftUI, AppKit, UIKit or AuthenticationServices import in `Sources/CloudflareKit`.
- `CloudflareKitUI` must not depend on `swift-support-kit`.
- `CloudflareCredential` case names are exactly `pastedToken` and `oauth(accountId:)`, so D1's and R2's stored JSON decodes unchanged.
- The review-demo trigger is `appreview-demo`, trimmed, case-insensitive.
- A sign-in cancel is silent (no error shown). Anything else shows `localizedDescription`.
- `signInWithWebSession()` never falls back to the loopback flow.
- Additive release: no existing public API changes signature. Version `1.5.0`, tag `v1.5.0` (local only; pushing is the owner's call).
- Every file follows the house comment style: say *why*, in full sentences, as the existing sources do.

## Review Focus

1. **Token pasted with surrounding whitespace or a trailing newline**: trimmed before listing, verifying and returning. Test in Task 3.
2. **Token edited after a multi-account picker appeared**: the picker and its selection reset, so the new token is never paired with the old token's account. Test in Task 3.
3. **Add or Sign in pressed again while one is running**: the second press is ignored, never a second concurrent flow. Test in Task 3.
4. **Account ID typed by hand for a token that cannot list accounts** (no Account Settings: Read): listing failure is not fatal, the ID is used as the name, and `verify` decides. Test in Task 3.
5. **Sign out of an account whose refresh token is missing from the Keychain**: `accountsSharingGrant` returns only itself, so the confirmation is the plain one, not "also signs out of" nobody. Test in Task 5.

---

## File map

| File | Responsibility |
| --- | --- |
| `Package.swift` | Adds the `CloudflareKitUI` product, target and test target. |
| `Sources/CloudflareKit/Accounts/CloudflareCredential.swift` | The credential enum and its `TokenProvider` resolver. |
| `Sources/CloudflareKit/Accounts/CloudflareAccountStore.swift` | One added line: public `configuration`. |
| `Sources/CloudflareKitUI/CloudflareReviewDemo.swift` | The shared App Review trigger. |
| `Sources/CloudflareKitUI/CloudflareWebSignIn.swift` | `ASWebAuthenticationSession` presenter, its errors, error classification, `signInWithWebSession()`. |
| `Sources/CloudflareKitUI/AddAccountModel.swift` | State and decisions of the add-account sections. |
| `Sources/CloudflareKitUI/AddAccountForm.swift` | The sections themselves (placed inside an app's `Form`). |
| `Sources/CloudflareKitUI/AccountsPaneLogic.swift` | Rows, access summary and sign-out wording for the pane. |
| `Sources/CloudflareKitUI/AccountsSettingsPane.swift` | The Settings › Accounts pane. |
| `Tests/CloudflareKitTests/CloudflareCredentialTests.swift` | Credential Codable fixtures and resolver. |
| `Tests/CloudflareKitUITests/*.swift` | Tests for the UI target's logic. |
| `README.md` | Documents the new product. |

---

### Task 1: `CloudflareCredential` and the store's public configuration

**Files:**
- Create: `Sources/CloudflareKit/Accounts/CloudflareCredential.swift`
- Modify: `Sources/CloudflareKit/Accounts/CloudflareAccountStore.swift` (after `public var accounts: [CloudflareAccount] = []`, line 158)
- Test: `Tests/CloudflareKitTests/CloudflareCredentialTests.swift`

**Interfaces:**
- Consumes: `TokenProvider`, `CloudflareAccountStore.tokenProvider(for:)`, `CloudflareAccountStore.account(id:)`.
- Produces:
  - `public enum CloudflareCredential: Codable, Equatable, Hashable, Sendable { case pastedToken; case oauth(accountId: String) }`
  - `public func tokenProvider(pastedToken: () throws -> String, accounts: CloudflareAccountStore?) throws -> TokenProvider`
  - `public enum CloudflareCredentialError: LocalizedError, Equatable, Sendable { case signedOut(accountID: String) }`
  - `CloudflareAccountStore.configuration: CloudflareOAuthConfiguration` (public, read-only)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CloudflareKitTests/CloudflareCredentialTests.swift`:

```swift
import Foundation
import Testing

@testable import CloudflareKit

/// The credential enum D1Explorer and R2Explorer each defined for themselves, now shared.
/// Its JSON is load-bearing: both apps have connections on disk in this exact shape, so the
/// fixtures below are copied from what their `ConnectionCredential` encodes today.
@Suite("Cloudflare credential")
@MainActor
struct CloudflareCredentialTests {

  @Test func pastedToken_decodesTheAppsStoredShape() throws {
    let stored = Data(#"{"pastedToken":{}}"#.utf8)
    #expect(try JSONDecoder().decode(CloudflareCredential.self, from: stored) == .pastedToken)
  }

  @Test func oauth_decodesTheAppsStoredShape() throws {
    let stored = Data(#"{"oauth":{"accountId":"abc123"}}"#.utf8)
    #expect(
      try JSONDecoder().decode(CloudflareCredential.self, from: stored)
        == .oauth(accountId: "abc123"))
  }

  @Test func bothCases_reencodeToTheSameShape() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(
      String(decoding: try encoder.encode(CloudflareCredential.pastedToken), as: UTF8.self)
        == #"{"pastedToken":{}}"#)
    #expect(
      String(
        decoding: try encoder.encode(CloudflareCredential.oauth(accountId: "abc123")),
        as: UTF8.self) == #"{"oauth":{"accountId":"abc123"}}"#)
  }

  @Test func pastedToken_resolvesToAFixedProvider() async throws {
    let provider = try CloudflareCredential.pastedToken.tokenProvider(
      pastedToken: { "secret" }, accounts: nil)
    #expect(try await provider.token() == "secret")
    #expect(provider.canRefresh == false)
  }

  @Test func pastedToken_rethrowsAMissingSecret() {
    #expect(throws: KeychainStore.KeychainError.self) {
      try CloudflareCredential.pastedToken.tokenProvider(
        pastedToken: { throw KeychainStore.KeychainError.notFound }, accounts: nil)
    }
  }

  @Test func oauth_withoutTheAccount_isSignedOut() {
    #expect(throws: CloudflareCredentialError.signedOut(accountID: "gone")) {
      try CloudflareCredential.oauth(accountId: "gone").tokenProvider(
        pastedToken: { "unused" }, accounts: nil)
    }
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CloudflareCredentialTests`
Expected: build failure, `cannot find 'CloudflareCredential' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/CloudflareKit/Accounts/CloudflareCredential.swift`:

```swift
import Foundation

/// How one connection or account authenticates: a token the user pasted, or a Cloudflare
/// sign-in shared with every other entry on the same account.
///
/// D1Explorer and R2Explorer each had this enum as `ConnectionCredential`, with these exact
/// case names. They are kept verbatim because the synthesized `Codable` form is on disk in
/// both apps; renaming a case would make every stored connection fail to decode.
public enum CloudflareCredential: Codable, Equatable, Hashable, Sendable {
  /// A pasted API token. Where it is stored is the app's decision: D1 and R2 key it by
  /// connection, KVExplorer by account.
  case pastedToken
  /// A Cloudflare sign-in. The refresh token lives in the account store, not here.
  case oauth(accountId: String)

  /// The provider a client should hold for this credential.
  ///
  /// - Parameter pastedToken: reads the app's own Keychain slot. Called only for
  ///   `.pastedToken`, and its error is rethrown as is, so a missing token still reads as
  ///   "not found in Keychain".
  /// - Parameter accounts: the app's account store, or nil where sign-in is unavailable.
  public func tokenProvider(
    pastedToken: () throws -> String,
    accounts: CloudflareAccountStore?
  ) throws -> TokenProvider {
    switch self {
    case .pastedToken:
      return .fixed(try pastedToken())
    case .oauth(let accountID):
      guard let accounts, accounts.account(id: accountID) != nil else {
        throw CloudflareCredentialError.signedOut(accountID: accountID)
      }
      return accounts.tokenProvider(for: accountID)
    }
  }
}

/// Why a credential could not produce a provider.
public enum CloudflareCredentialError: LocalizedError, Equatable, Sendable {
  /// The sign-in this credential names is no longer in the account store: signed out here,
  /// or signed out alongside another account from the same sign-in.
  case signedOut(accountID: String)

  public var errorDescription: String? {
    switch self {
    case .signedOut:
      "This account is signed out. Sign in with Cloudflare again to reach it."
    }
  }
}
```

Modify `Sources/CloudflareKit/Accounts/CloudflareAccountStore.swift`: directly after `public var accounts: [CloudflareAccount] = []` insert:

```swift

  /// The OAuth registration this store signs in with. Public so the UI product can read the
  /// app's https callback and scope list without every app passing them in a second time.
  public var configuration: CloudflareOAuthConfiguration { dependencies.oauth.configuration }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CloudflareCredentialTests`
Expected: 6 tests pass.

Then the whole suite, to check the store change broke nothing: `swift test`
Expected: all pass (Keychain round-trip cases may report as skipped, which is normal).

- [ ] **Step 5: Commit**

```bash
git add Sources/CloudflareKit/Accounts/CloudflareCredential.swift Sources/CloudflareKit/Accounts/CloudflareAccountStore.swift Tests/CloudflareKitTests/CloudflareCredentialTests.swift
git commit -m "Add CloudflareCredential, the pasted-token-or-sign-in enum both apps persist"
```

---

### Task 2: `CloudflareKitUI` target, the review-demo trigger, and in-app sign-in

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CloudflareKitUI/CloudflareReviewDemo.swift`
- Create: `Sources/CloudflareKitUI/CloudflareWebSignIn.swift`
- Test: `Tests/CloudflareKitUITests/CloudflareWebSignInTests.swift`
- Test: `Tests/CloudflareKitUITests/TestSupport.swift`

**Interfaces:**
- Consumes: `CloudflareAccountStore.configuration`, `CloudflareAccountStore.signIn(redirectURI:authorize:)`, `CloudflareOAuthError.cancelled`.
- Produces:
  - `public enum CloudflareReviewDemo { public static let trigger: String; public static func isTrigger(_ text: String) -> Bool }`
  - `public enum CloudflareWebSignInError: LocalizedError, Equatable, Sendable { case domainNotAssociated(String); case couldNotStart; case noHTTPSCallback; case unavailable }`
  - `@MainActor public final class CloudflareWebSignIn` with `public init()`, `@available(iOS 17.4, *) public func authorize(url: URL, host: String, path: String) async throws -> URL`, `public static func classify(_ error: (any Error)?, host: String) -> any Error`
  - `extension CloudflareAccountStore { @MainActor public func signInWithWebSession() async throws -> [CloudflareAccount] }`
  - Test helper `makeTestStore(httpsCallback:) -> CloudflareAccountStore` in `TestSupport.swift`, reused by Tasks 3 and 5.

- [ ] **Step 1: Add the target to `Package.swift`**

Replace the `products:` and `targets:` arrays with:

```swift
  products: [
    .library(name: "CloudflareKit", targets: ["CloudflareKit"]),
    // The account UI the three explorer apps share: in-app sign-in, the add-account
    // sections and the Settings pane. A separate product so a command-line consumer of
    // CloudflareKit never links SwiftUI or AuthenticationServices.
    .library(name: "CloudflareKitUI", targets: ["CloudflareKitUI"]),
  ],
  targets: [
    .target(name: "CloudflareKit"),
    .target(name: "CloudflareKitUI", dependencies: ["CloudflareKit"]),
    .testTarget(name: "CloudflareKitTests", dependencies: ["CloudflareKit"]),
    .testTarget(
      name: "CloudflareKitUITests", dependencies: ["CloudflareKitUI", "CloudflareKit"]),
  ]
```

Also replace the header comment's first line `// The Cloudflare client surface shared by D1Explorer and R2Explorer.` with
`// The Cloudflare client surface shared by D1Explorer, R2Explorer and KVExplorer.`

- [ ] **Step 2: Write the failing tests**

Create `Tests/CloudflareKitUITests/TestSupport.swift`:

```swift
import Foundation

@testable import CloudflareKit

/// An in-memory Keychain: three closures over a dictionary, as in CloudflareKitTests.
final class FakeKeychain: @unchecked Sendable {
  var items: [String: String] = [:]
}

/// A store that never touches disk, the network or the real Keychain.
@MainActor
func makeTestStore(
  keychain: FakeKeychain = FakeKeychain(),
  httpsCallback: CloudflareOAuthConfiguration.HTTPSCallback? = .init(
    host: "example.test", path: "/oauth/callback")
) -> CloudflareAccountStore {
  let configuration = CloudflareOAuthConfiguration(
    clientID: "test-client-id",
    appName: "TestApp",
    requiredScopes: ["d1.read", "account-settings.read"],
    optionalScopes: ["d1.write", "account-analytics.read"],
    redirectPorts: [53682],
    loggingSubsystem: "io.mgcrea.CloudflareKitUITests",
    httpsCallback: httpsCallback)
  let dependencies = CloudflareAccountStore.Dependencies(
    oauth: CloudflareOAuth(configuration: configuration),
    keychainKeyPrefix: "test.oauth.",
    readSecret: { key in
      guard let value = keychain.items[key] else {
        throw KeychainStore.KeychainError.notFound
      }
      return value
    },
    saveSecret: { value, key, _ in keychain.items[key] = value },
    deleteSecret: { key in keychain.items[key] = nil },
    isSynchronizable: { false })
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("accounts-\(UUID().uuidString).json")
  return CloudflareAccountStore(storageURL: url, dependencies: dependencies, loadsFromDisk: false)
}
```

Create `Tests/CloudflareKitUITests/CloudflareWebSignInTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter CloudflareKitUITests`
Expected: build failure, `no such module 'CloudflareKitUI'` or `cannot find 'CloudflareWebSignIn' in scope`.

- [ ] **Step 4: Implement**

Create `Sources/CloudflareKitUI/CloudflareReviewDemo.swift`:

```swift
import Foundation

/// App Review's way into an app's sample data, shared so every app has the same one.
///
/// A reviewer has no Cloudflare account, so each app ships a demo they reach by typing this
/// into the API token field of the add-account sections. It used to be the token field in
/// KVExplorer and the connection-name field in D1 and R2; one place means one sentence in
/// every app's review notes.
public enum CloudflareReviewDemo {
  public static let trigger = "appreview-demo"

  public static func isTrigger(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trigger
  }
}
```

Create `Sources/CloudflareKitUI/CloudflareWebSignIn.swift`:

```swift
import AuthenticationServices
import CloudflareKit
import Foundation
import os

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

private let log = Logger(subsystem: "io.mgcrea.CloudflareKitUI", category: "web-sign-in")

/// Presents Cloudflare's authorization page in-process and returns the URL it redirected to.
///
/// Used on both platforms. On iOS the loopback flow cannot work at all: opening the browser
/// backgrounds the app, and a suspended app never reads the redirect. On the Mac it worked,
/// and App Review rejected it (KVExplorer 1.0.0, Guideline 4): signing in through the
/// default browser is accepted only inside `ASWebAuthenticationSession`.
///
/// It needs the callback host associated with the app through **`webcredentials:`** in
/// Associated Domains, not `applinks:`, on every platform the app signs in from. A custom
/// scheme would need none of that and is not on offer: Cloudflare's OAuth client form
/// accepts only `http://` and `https://` redirects.
///
/// `prefersEphemeralWebBrowserSession` is deliberately left off: sharing the browser's
/// cookies is what makes an already-signed-in user's consent two taps instead of a password
/// and 2FA.
///
/// Moved from the copies in KVExplorer, D1Explorer and Almanac, unchanged in behaviour.
@MainActor
public final class CloudflareWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding
{
  public override init() {}

  /// Runs one round trip. The session is held by the continuation's closure rather than a
  /// stored property: it must outlive `start()`, and an abandoned sign-in should take its
  /// presenter with it.
  @available(iOS 17.4, *)
  public func authorize(url: URL, host: String, path: String) async throws -> URL {
    #if !os(macOS)
      // Resolved before the session exists: with no foreground window there is nothing to
      // present from, and an empty `UIWindow()` would only defer the same failure.
      guard let window = Self.foregroundWindow() else {
        throw CloudflareWebSignInError.couldNotStart
      }
      anchor = window
    #endif
    return try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: url, callback: .https(host: host, path: path)
      ) { callbackURL, error in
        if let callbackURL {
          continuation.resume(returning: callbackURL)
          return
        }
        let classified = Self.classify(error, host: host)
        if classified as? CloudflareOAuthError == .cancelled {
          log.notice("sign-in cancelled by the user")
        } else {
          let detail = (error as NSError?)?.localizedFailureReason ?? ""
          log.error(
            "authorization session failed: \(String(describing: classified), privacy: .public) \(detail, privacy: .public)"
          )
        }
        continuation.resume(throwing: classified)
      }
      session.presentationContextProvider = self
      guard session.start() else {
        // No anchor to present from, which on iOS means the scene is not foreground.
        log.error("authorization session refused to start")
        continuation.resume(throwing: CloudflareWebSignInError.couldNotStart)
        return
      }
    }
  }

  /// What a session failure means.
  ///
  /// `canceledLogin` is also what an unverifiable callback host reports, so the code alone
  /// cannot tell a user changing their mind from a broken deployment. The failure reason
  /// can. Matching Apple's wording is best-effort and fails safe: an unrecognised reason is
  /// still a cancel, which is what it was before.
  ///
  /// Compared by domain and code rather than by casting, so the result does not depend on
  /// how the error was bridged.
  public nonisolated static func classify(_ error: (any Error)?, host: String) -> any Error {
    guard let error else { return CloudflareWebSignInError.couldNotStart }
    let ns = error as NSError
    guard ns.domain == ASWebAuthenticationSessionError.errorDomain,
      ns.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue
    else { return error }
    let reason = ns.localizedFailureReason ?? ""
    if reason.contains("not associated with domain") {
      return CloudflareWebSignInError.domainNotAssociated(host)
    }
    return CloudflareOAuthError.cancelled
  }

  public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
    -> ASPresentationAnchor
  {
    MainActor.assumeIsolated {
      #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
          ?? ASPresentationAnchor()
      #else
        anchor ?? Self.foregroundWindow() ?? ASPresentationAnchor()
      #endif
    }
  }

  #if !os(macOS)
    private var anchor: UIWindow?

    private static func foregroundWindow() -> UIWindow? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
      return windows.first { $0.isKeyWindow } ?? windows.first
    }
  #endif
}

/// The failures that belong to in-app sign-in rather than to the OAuth flow.
public enum CloudflareWebSignInError: LocalizedError, Equatable, Sendable {
  /// The callback host is not associated with this build: the entitlement, the
  /// `apple-app-site-association` file, or the host itself disagree.
  case domainNotAssociated(String)
  /// No window to present from.
  case couldNotStart
  /// The app's OAuth configuration has no https callback, so there is nothing to sign in to.
  case noHTTPSCallback
  /// The system is older than the https callback API (iOS 17.4).
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .domainNotAssociated(let host):
      "This build isn't allowed to receive the sign-in redirect from \(host)."
    case .couldNotStart:
      "Sign-in couldn't open its window."
    case .noHTTPSCallback:
      "Sign in with Cloudflare isn't set up in this build."
    case .unavailable:
      "Signing in with Cloudflare needs iOS 17.4 or later. Paste an API token instead."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .domainNotAssociated:
      "Check that the site serves /.well-known/apple-app-site-association and that this build's Associated Domains entitlement names the same host."
    case .couldNotStart:
      "Bring the app to the foreground and try again."
    case .noHTTPSCallback, .unavailable:
      nil
    }
  }
}

extension CloudflareAccountStore {
  /// Signs in through ``CloudflareWebSignIn`` and returns every account the grant unlocked.
  ///
  /// Throws ``CloudflareWebSignInError/noHTTPSCallback`` when the configuration has no https
  /// callback, rather than falling back to the loopback flow: a silent fallback would send
  /// the Mac back to the default browser, which is how an app gets rejected.
  @MainActor
  public func signInWithWebSession() async throws -> [CloudflareAccount] {
    guard let callback = configuration.httpsCallback else {
      throw CloudflareWebSignInError.noHTTPSCallback
    }
    guard #available(iOS 17.4, *) else { throw CloudflareWebSignInError.unavailable }
    let presenter = CloudflareWebSignIn()
    return try await signIn(redirectURI: callback.redirectURI) { url in
      try await presenter.authorize(url: url, host: callback.host, path: callback.path)
    }
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter CloudflareKitUITests`
Expected: the review-demo tests (8 argument cases) and the 5 sign-in tests pass.

If strict concurrency rejects capturing `presenter` in the `authorize` closure, annotate that closure `{ @MainActor url in ... }`. Do not add `@unchecked Sendable`.

- [ ] **Step 6: Check the iOS build**

Run: `xcodebuild build -scheme CloudflareKitUI -destination 'generic/platform=iOS' -quiet`
Expected: `** BUILD SUCCEEDED **` (with `-quiet`, no output and exit 0).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CloudflareKitUI Tests/CloudflareKitUITests
git commit -m "Add CloudflareKitUI with in-app sign-in on both platforms and the review-demo trigger"
```

---

### Task 3: `AddAccountModel`

**Files:**
- Create: `Sources/CloudflareKitUI/AddAccountModel.swift`
- Test: `Tests/CloudflareKitUITests/AddAccountModelTests.swift`

**Interfaces:**
- Consumes: `CloudflareReviewDemo.isTrigger(_:)`, `CloudflareAccountsAPI.list(token:session:)`, `CloudflareAccountStore.signInWithWebSession()`, `CloudflareOAuthError.cancelled`.
- Produces:
  - `public enum AddAccountResult: Equatable, Sendable { case signedIn([CloudflareAccount]); case pastedToken(token: String, account: CloudflareAccount) }`
  - `@MainActor @Observable public final class AddAccountModel` with:
    - `public init(signIn: (@MainActor () async throws -> [CloudflareAccount])?, listAccounts: @escaping @Sendable (String) async throws -> [CloudflareAccount], verify: @escaping @Sendable (String, String) async throws -> Void, onReviewDemo: (@MainActor () -> Void)?, onFinish: @escaping @MainActor (AddAccountResult) -> Void)`
    - `public convenience init(accounts: CloudflareAccountStore?, verify:onReviewDemo:onFinish:)` (production wiring)
    - state: `token: String`, `accountID: String`, `candidates: [CloudflareAccount]`, `selectedCandidateID: String?`, `isSigningIn: Bool`, `isAdding: Bool`, `error: String?`, `canSignIn: Bool`, `hasSignedInBefore: Bool` (set by the form)
    - `public func signIn() async`, `public func addToken() async`, `public func tokenDidChange()`
    - `public var signInTitle: String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CloudflareKitUITests/AddAccountModelTests.swift`:

```swift
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
    AddAccountModel(
      signIn: signIn,
      listAccounts: { token in
        recorder.listedWith.append(token)
        if listFails { throw CloudflareAccountsError.http(status: 403, message: "") }
        return accounts
      },
      verify: { token, id in
        recorder.verified.append((token, id))
        if verifyFails { throw URLError(.userAuthenticationRequired) }
      },
      onReviewDemo: demo ? { recorder.demoEntered += 1 } : nil,
      onFinish: { recorder.finished.append($0) })
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
    #expect(model.error == "This build isn't allowed to receive the sign-in redirect from example.test.")
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AddAccountModelTests`
Expected: build failure, `cannot find 'AddAccountModel' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/CloudflareKitUI/AddAccountModel.swift`:

```swift
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

  @ObservationIgnored private let signInAction: (@MainActor () async throws -> [CloudflareAccount])?
  @ObservationIgnored private let listAccounts: @Sendable (String) async throws -> [CloudflareAccount]
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AddAccountModelTests`
Expected: all 18 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CloudflareKitUI/AddAccountModel.swift Tests/CloudflareKitUITests/AddAccountModelTests.swift
git commit -m "Add AddAccountModel: sign in, or paste a token and pick its account"
```

---

### Task 4: `AddAccountForm`

**Files:**
- Create: `Sources/CloudflareKitUI/AddAccountForm.swift`

**Interfaces:**
- Consumes: `AddAccountModel` (Task 3), `CloudflareAccountStore`.
- Produces: `public struct AddAccountForm: View` with
  `public init(accounts: CloudflareAccountStore?, tokenHint: String, verify: @escaping @Sendable (String, String) async throws -> Void, onReviewDemo: (@MainActor () -> Void)?, onFinish: @escaping @MainActor (AddAccountResult) -> Void)`.
  It renders **sections**, to be placed inside the app's own `Form`.

- [ ] **Step 1: Implement**

Create `Sources/CloudflareKitUI/AddAccountForm.swift`:

```swift
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
```

- [ ] **Step 2: Build on both platforms**

Run: `swift build`
Expected: `Build complete!`

Run: `xcodebuild build -scheme CloudflareKitUI -destination 'generic/platform=iOS' -quiet`
Expected: exit 0, no errors.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/CloudflareKitUI/AddAccountForm.swift
git commit -m "Add AddAccountForm, the add-account sections every app places in its sheet"
```

---

### Task 5: `AccountsPaneLogic`

**Files:**
- Create: `Sources/CloudflareKitUI/AccountsPaneLogic.swift`
- Test: `Tests/CloudflareKitUITests/AccountsPaneLogicTests.swift`

**Interfaces:**
- Consumes: `CloudflareAccount.declinedScopes(against:)`, `CloudflareAccountStore.accountsSharingGrant(with:)` (called by the pane, results passed in here).
- Produces:
  - `public struct PastedTokenAccount: Identifiable, Equatable, Sendable { public var id: String; public var name: String; public var usedBy: Int?; public init(id: String, name: String, usedBy: Int? = nil) }`
  - `public struct AccountRow: Identifiable, Equatable, Sendable` with `id: String` (`"signIn:<accountID>"` or `"token:<accountID>"`), `accountID: String`, `name: String`, `kind: AccountRow.Kind` where `enum Kind: Equatable, Sendable { case signedIn(declinedScopes: [String]); case pastedToken(usedBy: Int?) }`
  - `public enum AccountsPaneLogic` with:
    - `public static func rows(signedIn: [CloudflareAccount], pastedTokens: [PastedTokenAccount], configuration: CloudflareOAuthConfiguration) -> [AccountRow]`
    - `public static func accessSummary(declinedScopes: [String], scopeNouns: [String: String]) -> String`
    - `public static func usedBySummary(_ count: Int) -> String`
    - `public static func otherNames(sharing ids: [String], with accountID: String, accounts: [CloudflareAccount]) -> [String]`
    - `public static func signOutMessage(name: String, others: [String], appName: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CloudflareKitUITests/AccountsPaneLogicTests.swift`:

```swift
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
        CloudflareAccount(id: "z", name: "Zeta", grantedScopes: ["d1.write", "account-analytics.read"]),
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

  @Test func signOut_namesOneOther() {
    #expect(
      AccountsPaneLogic.signOutMessage(name: "Acme", others: ["Beta"], appName: "KVExplorer")
        == "Signing out of Acme also signs out of Beta, which was added in the same sign-in.")
  }

  @Test func signOut_namesTwoOthers() {
    #expect(
      AccountsPaneLogic.signOutMessage(
        name: "Acme", others: ["Gamma", "Beta"], appName: "KVExplorer")
        == "Signing out of Acme also signs out of Beta and Gamma, which were added in the same sign-in.")
  }

  @Test func signOut_namesSeveralOthers() {
    #expect(
      AccountsPaneLogic.signOutMessage(
        name: "Acme", others: ["Delta", "Beta", "Gamma"], appName: "KVExplorer")
        == "Signing out of Acme also signs out of Beta, Delta and Gamma, which were added in the same sign-in.")
  }

  /// The store's `accountsSharingGrant` includes the account itself; the pane drops it
  /// before asking for the message, and this pins that the drop is by ID, not by name.
  @Test func others_excludeTheAccountItselfByID() {
    let others = AccountsPaneLogic.otherNames(
      sharing: ["a", "b"], with: "a",
      accounts: [CloudflareAccount(id: "a", name: "Same"), CloudflareAccount(id: "b", name: "Same")])
    #expect(others == ["Same"])
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AccountsPaneLogicTests`
Expected: build failure, `cannot find 'AccountsPaneLogic' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/CloudflareKitUI/AccountsPaneLogic.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter AccountsPaneLogicTests`
Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CloudflareKitUI/AccountsPaneLogic.swift Tests/CloudflareKitUITests/AccountsPaneLogicTests.swift
git commit -m "Add the Accounts pane's rows, access summary and sign-out wording"
```

---

### Task 6: `AccountsSettingsPane`

**Files:**
- Create: `Sources/CloudflareKitUI/AccountsSettingsPane.swift`

**Interfaces:**
- Consumes: `AccountsPaneLogic`, `PastedTokenAccount`, `AccountRow` (Task 5); `CloudflareAccountStore.accounts`, `.configuration`, `.accountsSharingGrant(with:)`, `.signOut(accountID:)`; `CloudflareOAuth.connectedApplications`.
- Produces: `public struct AccountsSettingsPane: View` with
  `public init(accounts: CloudflareAccountStore?, pastedTokens: [PastedTokenAccount], scopeNouns: [String: String], removePastedToken: @escaping @MainActor (String) async -> Void, addAccount: @escaping @MainActor () -> Void, isDemo: Bool)`.

- [ ] **Step 1: Implement**

Create `Sources/CloudflareKitUI/AccountsSettingsPane.swift`:

```swift
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
        Button("Remove", role: .destructive) {
          Task {
            busyRowID = row.id
            defer { busyRowID = nil }
            await removePastedToken(row.accountID)
          }
        }
        .accessibilityIdentifier("accounts.remove.\(row.accountID)")
      }
      if busyRowID == row.id {
        ProgressView().controlSize(.small)
      }
    }
    .disabled(isDemo || busyRowID != nil)
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
```

- [ ] **Step 2: Build on both platforms**

Run: `swift build`
Expected: `Build complete!`

Run: `xcodebuild build -scheme CloudflareKitUI -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/CloudflareKitUI/AccountsSettingsPane.swift
git commit -m "Add AccountsSettingsPane, the shared Settings › Accounts"
```

---

### Task 7: Document, format and tag 1.5.0

**Files:**
- Modify: `README.md` (insert a section before `## Status`, line 257; update the `## Status` section)

**Interfaces:**
- Consumes: every public name from Tasks 1–6.
- Produces: tag `v1.5.0` (local).

- [ ] **Step 1: Format**

Run: `xcrun swift-format format --in-place --recursive Sources Tests`
Then: `xcrun swift-format lint --recursive Sources Tests`
Expected: no output from lint. Re-run `swift test` if formatting changed anything; expected all pass.

- [ ] **Step 2: Document the new product**

Insert before `## Status` in `README.md`:

```markdown
### `CloudflareCredential`

How one connection or account authenticates: `.pastedToken`, or `.oauth(accountId:)` for a
Cloudflare sign-in. The case names are the ones D1Explorer and R2Explorer already persist,
so their stored connections decode unchanged. `tokenProvider(pastedToken:accounts:)` turns
one into a `TokenProvider`; where the pasted token is stored stays the app's decision.

## `CloudflareKitUI`

A second product, so a command-line consumer of `CloudflareKit` never links SwiftUI. It is
how KVExplorer, D1Explorer and R2Explorer manage accounts the same way.

- **`CloudflareWebSignIn`** and `CloudflareAccountStore.signInWithWebSession()`: sign-in
  through `ASWebAuthenticationSession` on **both** platforms. The Mac used to open the
  default browser and wait on a loopback listener; App Review rejects that (Guideline 4).
  Needs the https callback in the app's configuration and `webcredentials:<host>` in its
  Associated Domains on every platform. Never falls back to loopback.
- **`AddAccountForm`**: the account sections of an add sheet. "Sign in with Cloudflare", or
  paste an API token (listing its accounts when no ID is given, then the app's own
  `verify`). Typing `appreview-demo` in the token field calls `onReviewDemo`.
- **`AccountsSettingsPane`**: Settings › Accounts. Sign-in and pasted-token accounts
  together; Sign Out confirms and names every account the same sign-in takes with it.
```

In `## Status`, add a line at the end of that section:

```markdown
1.5.0 adds `CloudflareCredential` and the `CloudflareKitUI` product.
```

- [ ] **Step 3: Final verification**

Run: `swift build && swift test`
Expected: `Build complete!`, then all tests pass.

Run: `xcodebuild build -scheme CloudflareKitUI -destination 'generic/platform=iOS' -quiet`
Expected: exit 0.

- [ ] **Step 4: Commit and tag locally**

```bash
git add README.md Sources Tests
git commit -m "Document CloudflareKitUI and CloudflareCredential for 1.5.0"
git tag -a v1.5.0 -m "CloudflareKitUI: shared account management and in-app sign-in"
```

Do **not** push the commits or the tag. The apps resolve the package from GitHub, so
adopting 1.5.0 needs `git push && git push origin v1.5.0`, which is the owner's call.
