# Developer ID provisioning profiles

`scripts/release.sh` embeds explicit **Developer ID** provisioning profiles into
the app and the system extension. macOS refuses to *launch* an app whose
restricted entitlements (Network Extension + `system-extension.install`) aren't
authorized by an embedded profile at runtime, and Xcode's *managed* profiles are
unreliable for this (its automatic Developer ID export silently strips those
entitlements). Explicit profiles are deterministic.

Put two `.provisionprofile` files here (any filenames — the script matches by
App ID):

1. **App** — for App ID `org.reactjs.native.NeoMac`
2. **Extension** — for App ID `org.reactjs.native.NeoMac.NeoTunnel`

## Creating them (once)

Prerequisite — both App IDs must have these capabilities enabled at
<https://developer.apple.com/account> → Identifiers:
- **Network Extensions**
- **System Extension**

Then, at <https://developer.apple.com/account> → **Profiles → ＋**:

1. Distribution → **Developer ID** → Continue.
2. Select the App ID (`org.reactjs.native.NeoMac`, then repeat for `…NeoTunnel`).
3. Select your **Developer ID Application** certificate.
4. Name it (e.g. `Junctus Neo App DevID` / `Junctus Neo Tunnel DevID`), Generate,
   and **Download**.
5. Move both downloaded files into this folder (`macos/profiles/`).

The release script verifies the app profile grants both Network Extension and
`system-extension.install`, and fails early if not — so if the profile is missing
a capability, re-check the App ID and regenerate the profile.

These files are environment-specific signing material; they're safe to commit for
a solo project but consider `.gitignore`-ing them if the repo is shared.
