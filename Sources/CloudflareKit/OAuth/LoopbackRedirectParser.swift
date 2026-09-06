import Foundation

/// The pure half of redirect handling: turning an HTTP request line into a verdict.
///
/// Split from the socket so it can be tested without binding a port. Everything that
/// decides whether a sign-in succeeded lives here; ``LoopbackRedirectListener`` only moves
/// bytes.
public enum LoopbackRedirectParser {

  /// Query parameters from an HTTP request line such as
  /// `GET /callback?code=abc&state=xyz HTTP/1.1`.
  ///
  /// Returns nil for anything that is not a well-formed request line. Browsers reliably
  /// send a request line first, but a port scanner or a stray `curl` will not, and those
  /// must not be mistaken for a redirect.
  public static func queryItems(requestLine: String) -> [String: String]? {
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return nil }
    // The target is origin-form (`/callback?...`), so give URLComponents an authority to
    // resolve against — it will not parse a bare path with a query otherwise.
    guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
      return nil
    }
    var result: [String: String] = [:]
    for item in components.queryItems ?? [] {
      result[item.name] = item.value ?? ""
    }
    return result
  }

  /// The authorization code, or the reason there isn't one.
  ///
  /// The `state` check is the whole defence against an attacker getting their own
  /// authorization code adopted by this app: anyone can reach a loopback port on the user's
  /// machine, so an unverified `code` arriving here is not evidence of anything.
  public static func outcome(query: [String: String], expectedState: String) -> Result<
    String, CloudflareOAuthError
  > {
    if let error = query["error"] {
      // The user pressed Cancel on the consent screen. Not a failure to report as one.
      if error == "access_denied" { return .failure(.cancelled) }
      return .failure(
        .server(status: 400, code: error, message: query["error_description"] ?? ""))
    }
    guard let state = query["state"], constantTimeEquals(state, expectedState) else {
      return .failure(.stateMismatch)
    }
    guard let code = query["code"], !code.isEmpty else {
      return .failure(.invalidResponse)
    }
    return .success(code)
  }

  /// Compares without leaking the position of the first difference through timing.
  ///
  /// A random 32-character state makes this close to paranoia, but a `==` that bails on the
  /// first mismatching byte is the kind of thing that is free to avoid now and awkward to
  /// notice later.
  public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in a.indices {
      difference |= a[i] ^ b[i]
    }
    return difference == 0
  }

  /// What the browser tab is left showing. Plain, self-contained, and with **no network
  /// references** — this page renders inside the user's browser, and a stylesheet, font or
  /// image fetched from anywhere would be a request the app caused off Cloudflare, which
  /// would quietly make a consumer's App Store privacy label wrong. Asserted by a test,
  /// because a single `<img>` added here would not otherwise be noticed.
  public static func responseBody(success: Bool, appName: String) -> String {
    let heading = success ? "Signed in" : "Sign-in failed"
    let message =
      success
      ? "You can close this tab and return to \(appName)."
      : "Return to \(appName) for details."
    return """
      <!doctype html><html><head><meta charset="utf-8"><title>\(appName)</title></head>
      <body style="font:16px -apple-system,system-ui,sans-serif;margin:4rem auto;max-width:26rem;text-align:center;color:#1d1d1f">
      <h1 style="font-size:1.25rem">\(heading)</h1><p style="color:#6e6e73">\(message)</p>
      </body></html>
      """
  }

  public static func httpResponse(success: Bool, appName: String) -> Data {
    let body = responseBody(success: success, appName: appName)
    let bytes = Data(body.utf8)
    let head = """
      HTTP/1.1 200 OK\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(bytes.count)\r
      Connection: close\r
      \r

      """
    return Data(head.utf8) + bytes
  }
}
