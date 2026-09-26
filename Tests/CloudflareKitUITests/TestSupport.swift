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
