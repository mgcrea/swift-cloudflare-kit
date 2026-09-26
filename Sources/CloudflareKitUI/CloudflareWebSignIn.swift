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
