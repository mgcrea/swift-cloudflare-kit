# Shared account management for KVExplorer, D1Explorer and R2Explorer

Date: 2026-09-26. Status: design approved in conversation, awaiting spec review.

## Why

KVExplorer 1.0.0 (build 34) was rejected under App Review Guideline 4: the Mac signed in
to Cloudflare in the default browser, which Apple accepts only through
`ASWebAuthenticationSession`. Build 45 fixed that by moving the Mac to the in-app session.
Two further problems came out of the fix:

- KVExplorer opens on a Cloudflare sign-in screen with nowhere else to go. D1Explorer and
  R2Explorer open on an empty state and let the user add a connection when they choose to.
- The three apps manage accounts three slightly different ways. D1 and R2 each have their
  own copy of the Settings › Accounts pane, and the two have drifted (destructive role,
  styling, wording). KVExplorer has no Accounts pane, a toolbar account menu, and a single
  pasted-token slot. D1 and R2 still sign in through the default browser on the Mac, so
  their next review can be rejected exactly as KVExplorer's was.

The goal is one way of managing Cloudflare accounts, implemented once in this package and
adopted by all three apps.

## Scope

"Aligned" covers **how accounts are managed**: adding one, the Settings › Accounts pane,
signing out or removing one, and how sign-in is presented. It does **not** cover what each
app's sidebar shows, which stays app-specific:

| App        | Sidebar entry                         | Credential per entry     |
| ---------- | ------------------------------------- | ------------------------ |
| KVExplorer | an account, its namespaces under it   | per account              |
| R2Explorer | a connection = one account            | per connection (UUID)    |
| D1Explorer | a connection = one database           | per connection (UUID)    |

Out of scope: Almanac (its own sign-in flow; it can adopt `CloudflareWebSignIn` later),
the loopback flow's removal (it stays for command-line consumers), anything in
`swift-support-kit`.

## Sub-projects, in order

1. **swift-cloudflare-kit 1.5.0**: this spec's main subject. Additive, no breaking change.
2. **KVExplorer adopts it**: empty state and Add Account replace the launch sign-in
   screen, pasted tokens become peer accounts, Accounts pane, the toolbar menu goes.
3. **D1Explorer adopts it**.
4. **R2Explorer adopts it**.

Each has its own implementation plan. 2–4 need 1 released and pinned.

## 1. What the package gains

### 1.1 `CloudflareCredential` (in `CloudflareKit`)

```swift
public enum CloudflareCredential: Codable, Equatable, Hashable, Sendable {
  case pastedToken
  case oauth(accountId: String)
}
```

The case names and the `accountId` label are **deliberately the ones D1 and R2 already
persist** (`ConnectionCredential`), so the synthesized `Codable` form is byte-identical and
their stored connections decode unchanged. A test pins the JSON of both cases against
fixtures copied from each app.

Plus a resolver, so every app turns a credential into a `TokenProvider` the same way:

```swift
extension CloudflareCredential {
  public func tokenProvider(
    pastedToken: () throws -> String,        // reads the app's own Keychain slot
    accounts: CloudflareAccountStore?
  ) throws -> TokenProvider
}
```

`.pastedToken` gives `.fixed`, `.oauth` gives `accounts.tokenProvider(for:)`. Where the
pasted token is stored stays the app's decision (D1/R2 key it by connection UUID,
KVExplorer by account ID).

### 1.2 New product `CloudflareKitUI`

A second library product and target, depending on `CloudflareKit`, SwiftUI and
AuthenticationServices. It does **not** depend on `swift-support-kit`: the pane is a plain
view that each app places in its own `SettingsScaffold` switch. `CloudflareKit` itself
stays UI-free for command-line consumers.

Platform floor stays macOS 15 / iOS 17. The https callback needs macOS 14.4 / iOS 17.4, so
the iOS path is `@available(iOS 17.4, *)` and falls back to a clear "update iOS" error below
it (every consuming app targets 26, so this is theoretical).

#### `CloudflareWebSignIn`

The `ASWebAuthenticationSession` presenter now copied into KVExplorer, D1Explorer and
Almanac (`WebAuthenticationSignIn`), moved here unchanged in behaviour:

- `.https(host:path:)` callback from `CloudflareOAuthConfiguration.httpsCallback`;
- tells a real cancel apart from an unassociated callback host
  (`CloudflareWebSignInError.domainNotAssociated(host)`) by the failure reason;
- `prefersEphemeralWebBrowserSession` off, so an already-signed-in user consents in two taps;
- used on **both** platforms. This is what fixes D1 and R2 on the Mac.

With one convenience on the store:

```swift
extension CloudflareAccountStore {
  @MainActor public func signInWithWebSession() async throws -> [CloudflareAccount]
}
```

It throws if the configuration has no `httpsCallback`, rather than falling back to
loopback: falling back silently is how an app ends up rejected again.

#### `AddAccountForm`

The account part of an add sheet, identical in all three apps. Each app wraps it in its
own sheet and title: KVExplorer and R2 finish on it; D1 continues to its database picker.

```swift
public struct AddAccountForm: View {
  public init(
    accounts: CloudflareAccountStore?,              // nil hides "Sign in with Cloudflare"
    verify: @escaping (String, String) async throws -> Void,  // app-specific check: token, accountID
    onReviewDemo: (() -> Void)?,                     // nil in the demo itself
    onFinish: @escaping (AddAccountResult) -> Void
  )
}

public enum AddAccountResult: Equatable, Sendable {
  case signedIn([CloudflareAccount])                 // every account the grant unlocked
  case pastedToken(token: String, account: CloudflareAccount)
}
```

Layout, top to bottom:

1. **Sign in with Cloudflare** (primary). Title becomes "Sign in to Another Account…" once
   `accounts` is non-empty, and "Waiting for Cloudflare…" while running. A cancel is
   silent. An unassociated host shows its own error naming the host.
2. **Use an API token** (disclosure, collapsed when sign-in is available, expanded when it
   is not). Token field, optional Account ID field, **Add** button.
   - Empty account ID: list the token's accounts (`CloudflareAccountsAPI.list`). None is an
     error, one is used, several show a picker in place.
   - Then `verify(token, accountID)`, the app's own check (KV lists namespaces, R2 lists
     buckets, D1 lists databases), so a token without the right permission fails here and
     not later in the sidebar.
   - The footer names the permission each app needs; the app passes the text in.
3. Errors in a section below, one at a time.

The logic lives in an `@Observable` `AddAccountModel` the view owns, so it is testable
without a view.

**App Review demo.** Typing `appreview-demo` (trimmed, case-insensitive) in the token field
and pressing Add calls `onReviewDemo` instead of validating. This moves D1's and R2's
trigger from the connection-name field to the token field, so all three apps share one
entry point. **Each app's App Review notes in App Store Connect must be updated in the
same release** (sub-projects 3 and 4).

#### `AccountsSettingsPane`

```swift
public struct AccountsSettingsPane: View {
  public init(
    accounts: CloudflareAccountStore?,
    configuration: CloudflareOAuthConfiguration,
    pastedTokens: [PastedTokenAccount],             // app-provided, see below
    removePastedToken: @escaping (String) async -> Void,   // account ID
    addAccount: @escaping () -> Void,               // app presents its own sheet
    isDemo: Bool
  )
}

public struct PastedTokenAccount: Identifiable, Equatable, Sendable {
  public var id: String          // Cloudflare account ID
  public var name: String
  public var usedBy: Int?        // connections using it; nil where the app has none (KVExplorer)
}
```

- Empty: "No Cloudflare accounts yet." and the **Add Account…** button.
- One section per account, sign-in and pasted-token accounts together, sorted by name:
  - name as the section title, **Account ID** monospaced and selectable;
  - a kind line: "Signed in with Cloudflare" plus the access level
    ("Full access" / "Read only: write access was declined", orange), or "API token";
  - "Used by N connections" (inflected) when `usedBy` is set, which only D1 and R2 do;
  - buttons: sign-in accounts get **Sign Out** (destructive) and **Manage on Cloudflare…**
    (`CloudflareOAuth.connectedApplications`); pasted-token accounts get **Remove**
    (destructive).
- **Sign Out confirms first**, and the confirmation lists every other account that goes
  with it (`accountsSharingGrant(with:)`): "Signing out of Acme also signs out of Beta and
  Gamma, which were added in the same sign-in." One account alone gets a plain confirm.
- A failed revoke keeps today's D1 wording: "Signed out on this device, but Cloudflare
  could not be told to revoke the grant…" plus the Manage link.
- **Add Account…** calls `addAccount`. The pane does not host `AddAccountForm` itself:
  D1 needs its database step, and the sheet should look the same wherever it is opened.
- In the demo, sign-in and Add Account are disabled (R2's behaviour today), and the pane
  shows the demo's accounts read-only.

## 2. Adoption, per app (summary; each gets its own plan)

### KVExplorer

- Launch with no account: an empty state (like D1's sidebar empty state) with
  **Add Account…**. No more `ConnectView` at the root.
- `ConnectionStore` becomes the account list: `accounts: [KVAccount]`, each
  `{ id, name, credential: CloudflareCredential }`, merged from the sign-in accounts and
  KVExplorer's own pasted-token accounts (Keychain `token.<accountID>`, list in
  UserDefaults). One entry per account ID; adding a token for an account already present
  says so instead of duplicating it.
- Drops the single active `connection`, `hiddenAccountIDs` / "Show in Sidebar",
  `use(signedInAccount:)` and `.chooseSignedInAccount`. Signing in adds every account the
  grant covers. Sidebar sections still fold.
- Sidebar: every account as a section (unchanged look), a "+" menu in the sidebar toolbar
  with **Add Account…** and, on the Mac, **Add Wrangler Project…**. Account header context
  menu: New Namespace…, Sign Out / Remove.
- Toolbar: the Accounts menu goes. Reload and New Namespace move to the sidebar "+" menu
  and the account context menu.
- An account whose Keychain secret is missing stays listed with a failed state offering
  **Sign In Again** or **Remove**, instead of an unexplained "Token not found in Keychain".
- Settings gains an **Accounts** pane; the macOS `Settings` scene gets `connections` in
  its environment.
- One-time migration: today's `api-token` plus `kv-explorer.connection` become one
  pasted-token account; the old keys are removed.
- Screenshot goldens regenerated (the toolbar changes).

### D1Explorer and R2Explorer

- `ConnectionCredential` becomes a typealias of `CloudflareCredential` (no data migration).
- The Cloudflare section of `AddConnectionSheet` becomes `AddAccountForm`; D1 then shows
  its database picker as today.
- `AccountsSettingsTab` is replaced by `AccountsSettingsPane`, with pasted tokens listed
  by account ID and "Used by N connections".
- The Mac signs in through `CloudflareWebSignIn`; `ENABLE_INCOMING_NETWORK_CONNECTIONS`
  and `network.server` go, as in KVExplorer build 45. Both already carry
  `webcredentials:` on the Mac and serve the association file.
- The demo trigger moves to the token field; App Review notes updated.

## 3. Testing

In this package (`swift test`, no network):

- `CloudflareCredential` Codable fixtures from D1 and R2 decode, and re-encode
  byte-identically.
- `tokenProvider(pastedToken:accounts:)`: both cases, and a missing sign-in account.
- `AddAccountModel`: demo trigger variants (and near-misses), empty token, token with no
  account, one account, several accounts then a pick, `verify` failure, sign-in cancel is
  silent, unassociated host error, "already added" is left to the app.
- `AccountsSettingsPane` grouping: merge and sort of both kinds, grant-sharing
  confirmation text for one, two, and several accounts.
- `CloudflareWebSignIn` error classification from `NSError` failure reasons.

In each app: its existing store tests move to the new model, plus migration tests
(KVExplorer), plus a manual Mac and iOS sign-in on a TestFlight build before resubmitting.

## Risks

- **Review notes drift.** Moving D1's and R2's demo trigger without updating their App
  Review notes locks the reviewer out. Mitigation: the adoption plans include the ASC
  update as a step, checked with `get_app_store_review_detail`.
- **Signing on the Mac.** The in-app session needs the Associated Domains capability in an
  explicit Mac profile; the wildcard team profile cannot carry it. Building once with
  `-allowProvisioningUpdates` creates it (as done for KVExplorer).
- **One sign-out, several accounts.** The kit revokes a whole grant. The confirmation
  names every account affected, so nobody loses three accounts expecting to lose one.
