#!/usr/bin/env bash
#
# Build, sign, notarize, and publish the macOS app as a GitHub release DMG.
#
#   scripts/release.sh v0.1.0
#
# This distributes OUTSIDE the App Store, so the app is Developer ID-signed,
# notarized by Apple, and stapled — the requirements for Gatekeeper to run it on
# other people's Macs without warnings.
#
# One-time setup (see docs/RELEASE.md) — you must do these; a script can't:
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. The App IDs org.reactjs.native.NeoMac and …NeoMac.NeoTunnel with the
#      "Network Extensions" capability enabled in the developer portal.
#   3. Notary credentials stored once:
#        xcrun notarytool store-credentials neo-notary \
#          --apple-id you@example.com --team-id 6P354D3NZY --password <app-specific-pw>
#   4. gh installed and authed:  brew install gh && gh auth login
#
# Overridable via env: TEAM_ID, SIGN_ID, NOTARY_PROFILE, REPO.

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/release.sh <version>   e.g. scripts/release.sh v0.1.0" >&2
  exit 2
fi

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="${TEAM_ID:-6P354D3NZY}"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-neo-notary}"
REPO="${REPO:-junctus/react-native}"

WORKSPACE="$APP_DIR/macos/NeoMac.xcworkspace"
SCHEME="NeoMac-macOS"
BUILD_DIR="$APP_DIR/build/release"
DERIVED="$BUILD_DIR/dd"
APP="$DERIVED/Build/Products/Release/NeoMac.app"
# The .systemextension bundle is named after its bundle id (PRODUCT_NAME =
# $(PRODUCT_BUNDLE_IDENTIFIER)) because OSSystemExtensionManager matches by the
# on-disk name, not just CFBundleIdentifier — so resolve it by glob post-build.
SYSEXT_DIR="$APP/Contents/Library/SystemExtensions"
NEO_BIN="$APP_DIR/native/Bin/neo"
NE_ENTITLEMENTS="$APP_DIR/macos/NeoTunnel/NeoTunnel.entitlements"
APP_ENTITLEMENTS_SRC="$APP_DIR/macos/NeoMac-macOS/NeoMac.entitlements"
PROFILE_DIR="$APP_DIR/macos/profiles"
DMG="$BUILD_DIR/JunctusNeo-$VERSION.dmg"

step() { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- preflight: fail early with actionable messages ------------------------
step "Preflight checks"
security find-identity -v -p codesigning | grep -q "$SIGN_ID" \
  || die "no '$SIGN_ID' certificate in the keychain — create one in your Apple Developer account (see docs/RELEASE.md)."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' not found — run 'xcrun notarytool store-credentials $NOTARY_PROFILE …' (see docs/RELEASE.md)."
command -v gh >/dev/null 2>&1 || die "gh not installed — 'brew install gh && gh auth login'."
gh auth status >/dev/null 2>&1 || die "gh not authenticated — run 'gh auth login'."
[ -f "$NEO_BIN" ] || die "missing $NEO_BIN — run 'npm run build:rust' first."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- locate the explicit Developer ID provisioning profiles ----------------
# Xcode's managed ("Direct") profiles are unreliable here — its automatic
# Developer ID export silently strips the restricted entitlements it can't
# provision. So we use EXPLICIT Developer ID profiles you create in the portal
# (each App ID must have Network Extensions + System Extension capabilities) and
# drop into macos/profiles/. See macos/profiles/README.md.
# Match by the profile's application-identifier so filenames don't matter.
find_profile() {
  local appid="$1" need_install="$2" p dec
  for p in "$PROFILE_DIR"/*.provisionprofile "$PROFILE_DIR"/*.mobileprovision; do
    [ -f "$p" ] || continue
    dec=$(security cms -D -i "$p" 2>/dev/null)
    echo "$dec" | grep -q "<string>$TEAM_ID.$appid</string>" || continue
    echo "$dec" | grep -q "packet-tunnel-provider-systemextension" || continue
    if [ "$need_install" = yes ]; then
      echo "$dec" | grep -q "system-extension.install" || continue
    fi
    echo "$p"; return 0
  done
  return 1
}
step "Locating Developer ID provisioning profiles"
[ -d "$PROFILE_DIR" ] || die "no macos/profiles/ — create the Developer ID profiles (see macos/profiles/README.md)."
APP_PROFILE=$(find_profile "org.reactjs.native.NeoMac" yes) || die "no Developer ID profile in macos/profiles/ for the app that grants both Network Extension and system-extension.install — see macos/profiles/README.md."
EXT_PROFILE=$(find_profile "org.reactjs.native.NeoMac.NeoTunnel" no) || die "no Developer ID profile in macos/profiles/ for the extension (needs the packet-tunnel-provider-systemextension NE type)."

# --- build unsigned, embed the profiles, sign with Developer ID ------------
# arm64 only: the Rust lib (native/Libs/libneo_ffi.a) is arm64-only. Universal =
# `rustup target add x86_64-apple-darwin` + `npm run build:rust`, then drop ARCHS.
step "Building (Release, unsigned, arm64)"
xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build || die "build failed"
[ -d "$APP" ] || die "build did not produce $APP"
SYSEXT="$(echo "$SYSEXT_DIR"/*.systemextension)"
[ -d "$SYSEXT" ] || die "the system extension is missing from the build: $SYSEXT_DIR"

step "Embedding profiles + signing with Developer ID (innermost first)"
cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
cp "$EXT_PROFILE" "$SYSEXT/Contents/embedded.provisionprofile"

# Stamp the release version into the built app + extension (BEFORE signing, which
# seals Info.plist). Every prior build shipped CFBundleVersion "1", so macOS kept
# serving STALE cached Info.plist metadata for this bundle id — masking a
# newly-added key (e.g. NSSystemExtensionUsageDescription) even after reinstall.
# A distinct version per release forces macOS to re-read it.
VNUM="${VERSION#v}"
for _pl in "$APP/Contents/Info.plist" "$SYSEXT/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VNUM" "$_pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VNUM" "$_pl"
done
APP_ENT="$BUILD_DIR/app-sign.entitlements"
cp "$APP_ENTITLEMENTS_SRC" "$APP_ENT"
/usr/libexec/PlistBuddy -c \
  "Add :com.apple.developer.system-extension.install bool true" "$APP_ENT" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :com.apple.developer.system-extension.install true" "$APP_ENT"
sign() { codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@"; }
while IFS= read -r -d '' item; do sign "$item"; done < <(
  find "$APP/Contents/Frameworks" -maxdepth 1 \
    \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)
[ -f "$APP/Contents/Resources/neo" ] && sign "$APP/Contents/Resources/neo"
sign --entitlements "$NE_ENTITLEMENTS" "$SYSEXT"
sign --entitlements "$APP_ENT" "$APP"

step "Verifying signatures and Gatekeeper policy"
codesign --verify --deep --strict --verbose=2 "$APP" || die "app signature verification failed"
codesign --verify --strict "$SYSEXT" || die "system extension signature verification failed"
spctl --assess --type execute --verbose=4 "$APP" || echo "  (spctl assess is advisory pre-notarization)"

# Definitive check: actually spawn the app. macOS refuses to launch an app whose
# restricted entitlements aren't authorized by the embedded profile, and that
# failure is invisible to codesign/notarization — so verify it here rather than
# ship a DMG that won't open.
step "Smoke-testing that the app launches"
if ! open "$APP" >"$BUILD_DIR/openout.txt" 2>&1; then
  grep -qi "spawn failed" "$BUILD_DIR/openout.txt" \
    && die "the signed app still fails to launch (restricted entitlement not authorized by the embedded profile)."
fi
sleep 2
osascript -e 'tell application id "org.reactjs.native.NeoMac" to quit' >/dev/null 2>&1 || true
pkill -f "NeoMac.app/Contents/MacOS/NeoMac" >/dev/null 2>&1 || true

# --- notarize + staple the app ---------------------------------------------
step "Notarizing the app"
APP_ZIP="$BUILD_DIR/NeoMac.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  || die "app notarization failed — check 'xcrun notarytool log' for the submission id."
xcrun stapler staple "$APP"

# --- build, notarize, staple the DMG ---------------------------------------
step "Building the DMG"
# Use a version-specific volume name and detach any leftover mount of it, so
# hdiutil's temporary mount can't collide with a Junctus Neo volume that's still
# attached (e.g. from testing a previous DMG) — that collision fails the create.
VOLNAME="Junctus Neo $VERSION"
[ -d "/Volumes/$VOLNAME" ] && hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" || die "hdiutil create failed"
rm -rf "$STAGE"
codesign --force --sign "$SIGN_ID" "$DMG"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
  || die "DMG notarization failed."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# --- publish the GitHub release --------------------------------------------
step "Publishing GitHub release $VERSION to $REPO"
NOTES="Junctus Neo $VERSION — signed & notarized macOS build (Apple Silicon).

Download the DMG, drag Junctus Neo to Applications, and open it. The first time
you start the tunnel, macOS will ask you to allow the VPN configuration."
gh release create "$VERSION" "$DMG" \
  --repo "$REPO" --title "Junctus Neo $VERSION" --notes "$NOTES"

step "Done"
echo "Released: https://github.com/$REPO/releases/tag/$VERSION"
echo "DMG:      $DMG"
