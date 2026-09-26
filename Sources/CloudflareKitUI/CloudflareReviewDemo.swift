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
