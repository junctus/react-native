#!/usr/bin/env bash
# Cross-build the neo Rust core (neo-ffi) for Android and regenerate the UniFFI
# Kotlin bindings. Outputs .so into android/app/src/main/jniLibs and the Kotlin
# into android/app/src/main/java/uniffi.
#
#   scripts/build-android-rust.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NEO_DIR="${1:-$APP_DIR/../neo}"
NDK_VER="${ANDROID_NDK_VERSION:-27.1.12297006}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/$NDK_VER}"
JNILIBS="$APP_DIR/android/app/src/main/jniLibs"
BINDGEN="$APP_DIR/rust/uniffi-bindgen/target/release/uniffi-bindgen"

[ -f "$NEO_DIR/Cargo.toml" ] || { echo "neo repo not found at $NEO_DIR" >&2; exit 1; }
command -v cargo-ndk >/dev/null || { echo "cargo-ndk missing — 'cargo install cargo-ndk'" >&2; exit 1; }

echo "==> building neo-ffi for Android (arm64-v8a + x86_64)"
( cd "$NEO_DIR" && cargo ndk -t arm64-v8a -t x86_64 -o "$JNILIBS" \
    build -p neo-ffi --features uniffi --release )

echo "==> regenerating UniFFI Kotlin bindings"
"$BINDGEN" generate --library "$JNILIBS/arm64-v8a/libneo_ffi.so" \
  --language kotlin --out-dir "$APP_DIR/android/app/src/main/java"

echo "==> done:"; ls "$JNILIBS"/*/libneo_ffi.so
