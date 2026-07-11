# Releasing Junctus Neo (outside the App Store)

The app is distributed as a **Developer ID-signed, notarized DMG** attached to a
GitHub release. That's what lets Gatekeeper run it on other people's Macs with no
"unidentified developer" warning. `scripts/release.sh` does the whole build →
sign → notarize → staple → DMG → GitHub-release pipeline in one command:

```sh
npm run build:rust          # ensure native/Bin/neo is current
scripts/release.sh v0.1.0
```

But it can only run after the one-time setup below — these are Apple-account and
machine steps that no script can do for you.

## One-time setup

### 1. Developer ID Application certificate
In Xcode → Settings → Accounts → your team (**6P354D3NZY**) → Manage
Certificates → **+** → **Developer ID Application**. This is different from the
"Apple Development" cert used for local runs. Confirm it's installed:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Network Extension capability on the App IDs
At <https://developer.apple.com/account> → Identifiers, for **both**
`org.reactjs.native.NeoMac` and `org.reactjs.native.NeoMac.NeoTunnel`, enable the
**Network Extensions** capability. This is what lets the Developer ID
provisioning profiles carry the `packet-tunnel-provider` entitlement. The release
script archives with `-allowProvisioningUpdates`, so Xcode will create/refresh
the matching Developer ID profiles automatically once the capability is on.

> The app target already has Hardened Runtime (added to its Release config), the
> extension already had it, and `release.sh` signs the bundled `neo` CLI — the
> three things notarization requires that weren't in place before.

### 3. Notary credentials (stored once in the keychain)
Create an **app-specific password** at <https://appleid.apple.com> (Sign-In &
Security → App-Specific Passwords), then:

```sh
xcrun notarytool store-credentials neo-notary \
  --apple-id you@example.com --team-id 6P354D3NZY --password <app-specific-password>
```

`neo-notary` is the profile name the script expects (override with
`NOTARY_PROFILE=...`).

### 4. GitHub CLI
```sh
brew install gh
gh auth login          # authorize against github.com, repo scope
```

## Running a release

```sh
scripts/release.sh v0.1.0
```

It will, failing early with a clear message if any prerequisite is missing:

1. sign the bundled `neo` CLI (hardened runtime + timestamp),
2. archive and export a Developer ID-signed `NeoMac.app`,
3. verify signatures / Gatekeeper policy,
4. notarize and staple the app,
5. build a DMG, then notarize and staple the DMG,
6. `gh release create <version>` with the DMG attached to `junctus/react-native`.

Output DMG: `build/release/JunctusNeo-<version>.dmg`.

## What users see

Downloading the DMG, dragging **Junctus Neo** to Applications, and opening it:
because it's notarized, Gatekeeper opens it with no warning. The only prompt is
macOS's normal "allow VPN configuration" dialog the first time the tunnel starts
— expected for any Network Extension app.

## Overrides

| Env var          | Default                         | Purpose                              |
|------------------|---------------------------------|--------------------------------------|
| `TEAM_ID`        | `6P354D3NZY`                    | Apple Developer team                 |
| `SIGN_ID`        | `Developer ID Application`      | Signing identity (name or SHA-1)     |
| `NOTARY_PROFILE` | `neo-notary`                    | `notarytool` keychain profile        |
| `REPO`           | `junctus/react-native`          | GitHub repo for the release          |

## Notes / gotchas

- **The `neo` CLI must stay signed.** `release.sh` signs `native/Bin/neo` before
  archiving; if you re-run `npm run build:rust` it's overwritten and the script
  re-signs it on the next release. Never hand-edit the exported bundle.
- Notarization is asynchronous; `--wait` blocks until Apple returns a verdict
  (usually a few minutes). On failure, `xcrun notarytool log <submission-id>
  --keychain-profile neo-notary` shows exactly what was rejected.
- This flow was set up but **not test-run here** (it needs the Developer ID cert
  and notary credentials, which live in your account). The first real run may
  surface a profile/entitlement detail to tweak — the error messages point at it.
