import CryptoKit
import Foundation
import Security

/// A PKCE verifier/challenge pair (RFC 7636).
///
/// The verifier never leaves the process until the token exchange, and the challenge is
/// what travels through the browser. That is the whole protection for a public client: an
/// attacker who intercepts the authorization code cannot spend it.
public struct PKCE: Sendable, Hashable {
  public let verifier: String

  /// 32 random bytes, base64url — 43 characters, comfortably inside RFC 7636's 43…128
  /// range and above its 256-bit entropy recommendation.
  public init() {
    var bytes = [UInt8](repeating: 0, count: 32)
    // SecRandomCopyBytes is the only CSPRNG guaranteed by the platform; `Int.random` is
    // not a security primitive.
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    self.verifier = Self.base64URL(Data(bytes))
  }

  /// Fixed-verifier initialiser, used by tests to check the S256 derivation against RFC
  /// 7636's worked example.
  public init(verifier: String) {
    self.verifier = verifier
  }

  public var challenge: String {
    Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  /// base64url with padding stripped, per RFC 7636 §A. Plain base64 would be rejected: `+`
  /// and `/` are not URL-safe and `=` is not allowed in the parameter.
  public static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// A random `state`, round-tripped through the browser and compared on the way back.
  ///
  /// Cloudflare rejects anything shorter than 8 characters. This returns 32 base64url
  /// characters from the same CSPRNG as the verifier.
  public static func makeState() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return base64URL(Data(bytes))
  }
}
