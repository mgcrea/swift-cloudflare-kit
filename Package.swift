// swift-tools-version: 6.0
import PackageDescription

// The Cloudflare client surface shared by D1Explorer, R2Explorer and KVExplorer.
//
// This is deliberately NOT part of `swift-support-kit`. That package cannot open a
// connection, and that is a requirement rather than a coincidence: it is what keeps the
// consuming apps' App Store privacy label at "Data Not Collected". Everything here talks
// to Cloudflare on the user's behalf, so it needs its own package rather than a version
// of that one which quietly gained a network dependency.
//
// The platform floor is macOS 15 / iOS 17 because nothing here needs more. The consuming
// apps target macOS 26; a floor raised to match them would lock out other consumers for
// no gain.
let package = Package(
  name: "swift-cloudflare-kit",
  platforms: [.macOS(.v15), .iOS(.v17)],
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
)
