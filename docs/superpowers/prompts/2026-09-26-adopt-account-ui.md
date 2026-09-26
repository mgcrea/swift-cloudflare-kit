# Adopt swift-cloudflare-kit 1.5.1 (CloudflareKitUI) in this app

You are working in **D1Explorer** (`~/Projects/apps/d1-explorer`) or **R2Explorer**
(`~/Projects/apps/r2-explorer`). The two get the same change, so check which repo you are in
and use the facts for that app below.

## Why this exists

KVExplorer 1.0.0 was rejected under App Review Guideline 4. On the Mac it signed in to
Cloudflare in the default browser, and Apple accepts that only through
`ASWebAuthenticationSession`. D1Explorer and R2Explorer still sign in that way on the Mac,
so their next review can be rejected for the same reason.

The fix went further than the sign-in call. The three apps now manage Cloudflare accounts
the same way, implemented once in `swift-cloudflare-kit` (`~/Projects/swift-cloudflare-kit`,
tag `v1.5.1`). KVExplorer has already adopted it and is back in review on build 57. You are
doing the same adoption for this app.

## Read these first

1. **The spec** (approved, so skip brainstorming):
   `~/Projects/swift-cloudflare-kit/docs/superpowers/specs/2026-09-26-account-management-ui-design.md`.
   Read "Scope" and "§2 Adoption → D1Explorer and R2Explorer" closely. The spec is the
   contract for this work.
2. **The kit's README**, sections `CloudflareCredential` and `CloudflareKitUI`, plus the
   sources in `Sources/CloudflareKitUI/`:
   - `CloudflareWebSignIn`
   - `AddAccountModel` / `AddAccountForm`
   - `AccountsPaneLogic` / `AccountsSettingsPane`
   - `CloudflareReviewDemo`
3. **KVExplorer as the reference implementation**, in `~/Projects/apps/kv-explorer`:
   - Commits `73bd16a..5b3ede3` show the adoption.
   - `27ffa19` moves it to 1.5.1.
   - The plan is at `docs/superpowers/plans/2026-09-26-kvexplorer-accounts.md`.
   - The files to look at are `Views/AddAccountSheet.swift` (wraps `AddAccountForm`),
     `Views/SettingsView.swift` (`AccountsPane` wraps `AccountsSettingsPane`) and
     `Services/ConnectionStore.swift`.

   Copy its shape wherever this app's model allows. Where the model differs, follow this
   app.

## What changes (spec §2)

- **Package.** Pin `swift-cloudflare-kit` to `upToNextMinorVersion` from **1.5.1** (both
  apps are on 1.4.2 today). Link the `CloudflareKitUI` product into the app target and the
  test target, and update `Package.resolved`.
- **Credential type.** `ConnectionCredential` becomes
  `typealias ConnectionCredential = CloudflareCredential`. Existing data needs no migration,
  because the kit's type encodes byte-for-byte like the app's enum.
  - Prove it with an app test that decodes a real persisted `Connection` JSON fixture and
    re-encodes it identically.
- **Sign-in.**
  - Delete the app's own `Services/WebAuthenticationSignIn.swift` and its tests.
  - Sign in through the kit's `CloudflareWebSignIn` / `signInWithWebSession()` on **both**
    platforms. The Mac stops using the loopback listener.
  - In `CloudflareAccountGlue.swift`, the macOS loopback branch goes.
  - Remove `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES` from both configurations in the
    pbxproj, so that `com.apple.security.network.server` is no longer granted.
  - Keep `com.apple.security.network.client` and the `webcredentials:` associated domain.
- **Add Account.**
  - In `AddConnectionSheet`, the Cloudflare credential section becomes the kit's
    `AddAccountForm`. Its sections sit inside the app's own `Form`.
  - D1 then shows its database picker exactly as it does today.
  - Local SQLite (D1), and anything else that is not a Cloudflare account, stays as it is.
- **Settings.** Replace `AccountsSettingsTab` with `AccountsSettingsPane`:
  - Pasted tokens are listed by account ID, with "Used by N connections".
  - Pass `scopeNouns` for this app's OAuth scopes. KVExplorer maps
    `workers-kv-storage.write` to "write access". Use the D1 or R2 equivalents from this
    app's `CloudflareOAuthRegistration`.
- **Review demo.**
  - The trigger moves to the token field, and the kit detects it via
    `CloudflareReviewDemo.isTrigger`. The string stays `appreview-demo`.
  - Today it is the **connection name**, so the old name path goes.
  - `ReviewDemo`'s tests move with it.
- **Sidebar.** The sidebar and the "connection" concept do not change. D1 has one
  connection per database and R2 has one per account.

## App facts (checked on 2026-09-26)

A snapshot, so recheck each row in the repo before relying on it.

|                      | D1Explorer                                                  | R2Explorer                                                                    |
| -------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Xcode dir            | `apps/apple`, target `SwiftD1`                              | `apps/apple`, target `SwiftR2`                                                |
| Swift language mode  | 6.0                                                         | 5.0 (leave it; not part of this change)                                       |
| Associated domain    | `webcredentials:d1-explorer.mgcrea.io`                      | `webcredentials:r2-explorer.mgcrea.io`                                        |
| Git state            | `main` 2 ahead of origin (`9d77a38`, `6995196`), not pushed | `main` 1 ahead (`42833df`), not pushed                                        |
| Review notes in repo | `docs/app-review-notes.md`                                  | none; read the live text with `app_store_connect_get_app_store_review_detail` |
| Write scopes to name | `d1.write`                                                  | `workers-r2.write`, `workers-r2-bucket-item.write`                            |

`9d77a38` in D1 patches its own `WebAuthenticationSignIn.swift` with the same fix kit
1.5.1 carries, so that file is deleted by this work. Leave the unpushed commits alone:
branch from `main` as it is, and never push.

## Lessons from KVExplorer

- **Sheets and dialogs.** Attach `.sheet` / `.confirmationDialog` to the main view chain,
  not inside another `.sheet(item:)`. KVExplorer shipped a Critical bug that way: Add
  Account never presented.
  - Verify in the iOS Simulator (cupertino-simulator / ios-simulator MCPs) that Add
    Account opens, that Cancel on sign-in is silent, and that `appreview-demo` enters the
    demo.
- **Stale kit module.** After the package bump, a stale `CloudflareKit` module can linger.
  Clear it by deleting `Build/` and `ModuleCache.noindex` under the repo's DerivedData
  path, not by editing code.
- **Imports.** `MemberImportVisibility` is on, so `import CloudflareKit` /
  `CloudflareKitUI` in every file that uses their types.
- **Type-checker crashes.** Swift 6.4's type checker crashes on large inline closures
  passed to the kit's initialisers. Hoist them into typed `let`s.
- **Actor isolation.** A `nonisolated` helper touched from the kit's callbacks must not be
  MainActor-isolated by the app's default.
- **Don't reimplement the kit.** The kit already handles:
  - the token-edited-while-verifying race (`isCurrent`)
  - Remove confirmation for pasted tokens (Cloudflare shows a token only once)
  - sign-out naming every account a grant covers

  Don't rebuild any of these in the app.

- **Real Mac data.** Do not launch the real Mac app against the user's real data: it
  shares the Keychain and defaults with the store build. Use tests and the Simulator. Ask
  before anything that touches real accounts.

## How to work

- Write a plan with `superpowers:writing-plans` in `docs/superpowers/plans/`. The user
  chose native execution for the previous two sub-projects, so ask how to execute.
- Then run `superpowers:executing-plans` with TDD, on a worktree branch
  `feature/shared-accounts`.
- Match the repo's conventions:
  - Commits look like `feat(apple): …` / `fix(apple): …` (see `git log`).
  - Run swift-format, 2 spaces, 100 columns.
  - Formatting and tests go through the Makefile targets.
- Regenerate the screenshot goldens if the UI changed, and inspect them before accepting.
- Update the CHANGELOG and the in-repo review notes.
- Finish with a code review, then `superpowers:finishing-a-development-branch`.

## Stop and ask before

- pushing any branch, or merging into `main`
- uploading a TestFlight build
- any App Store Connect write

For App Store Connect, draft the new review notes. They should read like KVExplorer's:
"Add Account… → expand 'Use an API token' → type `appreview-demo` → Add", plus a
"Changes since the previous review" note on in-app sign-in and the dropped `network.server`.
Show that draft to the user instead of applying it.

## Report back

In a few lines, cover:

- what landed, by commit
- test counts and whether both platforms build
- what you verified in the Simulator, and what is left for a real Mac or TestFlight run
- anything in the spec you could not follow for this app, and why
