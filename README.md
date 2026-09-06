# swift-cloudflare-kit

[![swift](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![platforms](https://img.shields.io/badge/platforms-macOS%2015%20%7C%20iOS%2017-lightgrey.svg)](#requirements)
[![license](https://img.shields.io/github/license/mgcrea/swift-cloudflare-kit.svg)](./LICENSE)

The Cloudflare client surface shared by [D1Explorer](https://d1-explorer.mgcrea.io) and
[R2Explorer](https://r2-explorer.mgcrea.io) — credential storage and per-request token
resolution, extracted so the two apps stop maintaining two copies of it.

## Why this is not part of `swift-support-kit`

[`swift-support-kit`](https://github.com/mgcrea/swift-support-kit) **cannot open a
connection**, and that is a requirement rather than a coincidence: it is what keeps the
consuming apps' App Store privacy label at "Data Not Collected". Everything here exists to
talk to Cloudflare on the user's behalf, so it needs its own package rather than a version of
that one which quietly gained a network dependency.

## What it holds

### `TokenProvider`

How a client obtains its bearer token, resolved **per request** rather than captured at
`init`.

```swift
let client = SomeClient(token: .fixed(pastedAPIToken))
let client = SomeClient(token: .renewing { try await accountStore.accessToken() })
```

An OAuth access token expires in minutes. A client built once and held by a window for an
afternoon goes stale, and the failure surfaces as `.unauthorized` — telling the user their
token was revoked when it had merely aged. Reading through a provider keeps that fix out of
every call site, and keeps the `makeService(for:)` factories **synchronous**, which matters
because they are called from SwiftUI `body` and `.task`.

### `KeychainStore`

Generic-password storage, namespaced per app.

```swift
let store = KeychainStore(service: "com.swiftd1")
try store.save(token, forKey: connection.keychainKey, synchronizable: syncEnabled)
let token = try store.read(forKey: connection.keychainKey)
```

`service` is a constructor argument, not a constant, because it namespaces every item and
each app owns its own. Two apps sharing one service string would read each other's
credentials.

`synchronizable` is stamped **at save time**, so flipping the Settings toggle does not
retroactively move credentials already stored. That is why `isSynchronizable(forKey:)` reads
the attribute back instead of reporting the preference — the stored flag is the only truthful
answer to "is *this* token syncing?".

#### Four errors, deliberately distinct

| Case | Means | Fix |
| --- | --- | --- |
| `.notFound` | nothing stored under this key | paste a credential |
| `.readFailed(OSStatus)` | the Keychain declined to answer | unlock the keybag, check entitlements |
| `.malformed` | the item exists, its bytes are not UTF-8 | re-authenticate |
| `.saveFailed(OSStatus)` | the write was refused | — |

**Do not reach these cases through a typealias in a `catch`.** `catch
MyShim.KeychainError.notFound`, where that is a typealias to this enum, does not compile — a
catch clause matches against `any Error`, so the case must be reachable as an enum-element
pattern, and a typealias is not. Write `catch KeychainStore.KeychainError.notFound`.

The two apps disagreed about `.malformed` before this package existed. One reported an
undecodable payload as `.notFound`, which claims an item that exists does not; the other
reported it as `.readFailed(errSecSuccess)`, which renders as "Keychain read failed (OSStatus
0)". Neither was true.

## Requirements

macOS 15+ / iOS 17+, Swift 6. The floor is lower than the consuming apps (macOS 26) because
nothing here needs more.

## Testing

```sh
swift test
```

The Keychain round-trip cases **skip** outside a signed host app. The data-protection
keychain requires a `keychain-access-groups` entitlement and an unlocked user keybag, and a
bare SwiftPM test bundle has neither — the suite probes for that and gates those cases rather
than failing and being explained away in a comment. `-34018` (`errSecMissingEntitlement`) and
`-25308` (`errSecInteractionNotAllowed`) are the environment saying no, not a regression.

## Status

First extraction pass. Still living in both app repos and **not yet here**:
`CloudflareOAuth` + `LoopbackRedirectListener` (the largest win and the most drift),
`CloudflareAccountStore`, and the GraphQL transport that both apps reimplement — including
its two Cloudflare quirks, an HTTP 200 carrying an `errors` array, and a missing permission
that has to read as an instruction rather than an error.

## License

MIT
