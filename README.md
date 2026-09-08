# swift-cloudflare-kit

[![swift](https://img.shields.io/badge/swift-6.0-orange.svg)](https://swift.org)
[![platforms](https://img.shields.io/badge/platforms-macOS%2015%20%7C%20iOS%2017-lightgrey.svg)](#requirements)
[![license](https://img.shields.io/github/license/mgcrea/swift-cloudflare-kit.svg)](./LICENSE)

The Cloudflare client surface shared by [D1Explorer](https://d1-explorer.mgcrea.io) and
[R2Explorer](https://r2-explorer.mgcrea.io) — OAuth, the loopback redirect, credential
storage, per-request token resolution and the GraphQL analytics transport, extracted so the
apps stop maintaining two copies of it.

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

### `CloudflareOAuth`

The authorization-code + PKCE flow against `dash.cloudflare.com`. **A public client: there is
no secret anywhere, in this package or in a consumer.** A shipped binary cannot keep one, so
clients register with `token_endpoint_auth_method: "none"` and every leg is protected by PKCE
— the `code` is worthless to anyone without the matching verifier.

```swift
let oauth = CloudflareOAuth(configuration: .init(
  clientID: "0dee75df3cb92c56ce49cb64a9e702a6",
  appName: "D1Explorer",
  requiredScopes: ["d1.read", "account-settings.read"],
  optionalScopes: ["d1.write", "account-analytics.read"],
  redirectPorts: [53682, 53683, 53684, 53685],
  loggingSubsystem: "io.mgcrea.SwiftD1"))
```

`CloudflareOAuthConfiguration` is the whole point of the extraction: the flow is identical
everywhere, and only four things genuinely differ.

| | Why it cannot be shared |
| --- | --- |
| `clientID` | registered per app; sharing one makes users consent to another app's name, and revoking one grant would revoke the other's |
| scopes | asking for a scope the client is not registered for fails the whole authorization as `invalid_scope`, so they cannot be unioned |
| `redirectPorts` | only to avoid colliding with a sibling app mid-sign-in — see below |
| `appName` | shown in the browser tab the redirect lands on, where the user is outside the app |

**On ports.** An earlier comment in D1Explorer said Cloudflare matches `redirect_uris`
exactly, so every port had to be registered. That was wrong, and R2Explorer's copy had
already corrected it: Cloudflare applies RFC 8252 §7.3, so the loopback **port is not
matched** (the path is). The fixed list is collision-avoidance between sibling apps, not a
Cloudflare requirement.

`offline_access` is appended by `allScopes` rather than kept in `requiredScopes`, because
that list drives consent-screen copy and the declined-scope comparison and should stay a list
of things the *app* does. **Requesting it is not optional and not automatic**: registering
`refresh_token` in `grant_types` only makes the scope available, and omitting it yields an
access token with no refresh token, a grant that dies at the first expiry, and a user bounced
back to the browser mid-session.

### `LoopbackRedirectListener` and `LoopbackRedirectParser`

A one-shot loopback HTTP listener, split from the pure parser so every decision about whether
a sign-in succeeded is testable without binding a port.

`ASWebAuthenticationSession` cannot serve *this* redirect — its `callbackURLScheme` cannot
be `http`, and Cloudflare does not accept a custom scheme as a `redirect_uri`. A consuming
app target must set `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES`; under the App Sandbox the
bind otherwise fails with no useful error and the symptom is a sign-in that hangs until it
times out.

**This path is macOS and CLI only.** See the https callback below for iOS, where it cannot
work at all.

The page left in the browser references **nothing off-device** — no stylesheet, font or
image. A single `<img>` would be a request the app caused off Cloudflare and would quietly
make a consumer's privacy label wrong, so a test asserts it.

### The https callback, and why iOS needs one

`openURL` sends the user to the system browser, which **backgrounds the app**. A suspended
app's `NWListener` is not serviced, so the redirect completes its TCP handshake into the
kernel backlog and is then never read: sign-in ends in `.timedOut`, after a wait that does
not advance while the app is suspended, so the error does not even appear until the user
comes back by themselves. It works on device only by racing the grace period iOS grants a
backgrounding app — fine when the browser is already signed in and consent is two taps,
hopeless on a first run with a password and 2FA.

`ASWebAuthenticationSession` removes the race rather than widening it, by presenting the
authorization page in-process so the app is never backgrounded. Its callback cannot be
`http`, so it needs a registered https redirect:

```swift
CloudflareOAuthConfiguration(
  …,
  httpsCallback: .init(host: "example.mgcrea.io", path: "/oauth/callback"))

// then, instead of signIn(openURL:aroundWait:)
try await store.signIn(redirectURI: callback.redirectURI) { url in
  try await session.authorize(url: url, host: callback.host, path: callback.path)
}
```

`authorize` is injected because the session needs a presentation anchor — a `UIWindow` — and
this package stays free of UIKit so a consumer's link line does too.

**Four things have to agree on that string and nothing checks that they do:** the redirect
URL registered on the OAuth client, `webcredentials:<host>` in the app's Associated Domains
entitlement (**not** `applinks:`, which is the easy mistake), the
`apple-app-site-association` served from that host, and the value here. A mismatch is not an
error anywhere — it is a sign-in that opens the sheet and then reports a cancel, because
`canceledLogin` is also what an unverifiable callback host returns.

The association file must be served over https from the callback host as `200`,
`content-type: application/json`, with **no redirect in between** — a `301` to `www.` or to
a trailing slash fails silently, which is the usual way this breaks.

`state` is checked identically on both transports, and deliberately so:
`ASWebAuthenticationSession` verifies that the *app* is entitled to the callback host, not
that the response is the one this flow asked for.

### `CloudflareGraphQL`

The analytics endpoint, and its two traps: a failure arrives as **HTTP 200 carrying an
`errors` array**, and a missing permission has to read as an instruction rather than an
error.

Both apps had reimplemented this and the copies had drifted in ways that changed behaviour:

| | D1Explorer | R2Explorer | here |
| --- | --- | --- | --- |
| `message` | `String?` | `String` | `String?` |
| several errors | reported `.first` | joined with `"; "` | joined |
| accepted status | `200` only | `200...299` | `200...299` |
| permission words | 6, incl. `not entitled`, `access denied` | 6, incl. `unauthorised`, `not authorized` | the union of both |

That last row is the one that mattered: the same Cloudflare response could read as a fixable
instruction in one app and a generic failure in the other.

### `CloudflareAccountStore`

The accounts a user has signed in to, their grants, and the token refresh that keeps them
alive. `@Observable`, so a consumer injects it through `@Environment`.

Everything app-shaped is injected through `Dependencies` rather than imported — the Keychain
is three closures, storage is a URL, and listing accounts is this package's own
`CloudflareAccountsAPI`. That is what lets one store back two apps whose Keychain
namespaces, storage directories and connection models all differ.

```swift
CloudflareAccountStore(
  storageURL: Self.defaultStorageURL(),
  dependencies: .init(
    oauth: .d1Explorer,
    keychainKeyPrefix: "com.swiftd1.oauth.",
    readSecret: { try KeychainHelper.read(forKey: $0) },
    saveSecret: { try KeychainHelper.save($0, forKey: $1, synchronizable: $2) },
    deleteSecret: { KeychainHelper.delete(forKey: $0) },
    isSynchronizable: { UserDefaults.standard.bool(forKey: "iCloudKeychainSync") },
    session: D1Client.defaultSession))
```

Three rules in here are worth knowing before changing anything:

**Refreshes are serialised through an actor.** On launch several views fire at once against
the same account. If each saw an expired token and refreshed independently, Cloudflare would
rotate the refresh token several times and all but one of those exchanges would invalidate
the rest — the user would be signed out by their own app opening a window.

**Signing out is grant-shaped, not account-shaped.** One authorization can unlock several
Cloudflare accounts sharing one refresh token, so revoking on behalf of one kills the others
too. `accountsSharingGrant(with:)` is what makes local state match what Cloudflare just did.
Revocation goes first: deleting only local state leaves a live grant the user believes they
cancelled. If it fails, local state is cleared anyway — someone who asked to sign out must
end up signed out — and the error is rethrown so the caller can point at Connected
Applications.

**A refresh response may or may not rotate the refresh token.** Writing `response.refreshToken`
unconditionally overwrites a good stored token with nothing on the responses that reuse the
old one, signing the user out at the following expiry.

`loadsFromDisk: false` gives a demo or screenshot build an empty store, so a run on a
developer's machine never renders their real account names.

## Status

Extraction complete: `CloudflareOAuth`, `LoopbackRedirectListener`/`Parser`, `PKCE`,
`CloudflareGraphQL`, `CloudflareAccount`, `CloudflareAccountsAPI`, `CloudflareAccountStore`,
`TokenProvider` and `KeychainStore` all live here, and neither app carries a copy.

One sharp edge is stated rather than papered over: `CloudflareAccountStore.accessToken(for:)`
is not main-actor isolated — clients call it from arbitrary contexts — and it reads
`accounts` to find a Keychain key. Every *mutation* of `accounts` is `@MainActor`. Closing
the read means moving the id-to-key mapping into the actor, which is a change to make
deliberately rather than as a side effect of an extraction.

## License

MIT
