#!/usr/bin/env bash
# Build the neo Rust core for the Mac app:
#   - libneo_ffi.a (static lib the app links, UniFFI feature on)
#   - UniFFI-generated Swift bindings
#   - the `neo` CLI daemon (bundled into the app's Resources)
#
# Usage: scripts/build-rust.sh [path-to-neo-repo]
# Builds arm64 always; adds x86_64 + lipo when that rustup target is installed.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NEO_DIR="${1:-$APP_DIR/../neo}"
NATIVE_DIR="$APP_DIR/native"

[ -f "$NEO_DIR/Cargo.toml" ] || { echo "neo repo not found at $NEO_DIR" >&2; exit 1; }

echo "==> building uniffi-bindgen helper"
cargo build --release --manifest-path "$APP_DIR/rust/uniffi-bindgen/Cargo.toml"
BINDGEN="$APP_DIR/rust/uniffi-bindgen/target/release/uniffi-bindgen"

cd "$NEO_DIR"

echo "==> building neo-ffi (arm64)"
cargo build -p neo-ffi --features uniffi --release --target aarch64-apple-darwin
FFI_ARM="target/aarch64-apple-darwin/release/libneo_ffi.a"

echo "==> building neo CLI (arm64)"
cargo build -p neo-cli --release --target aarch64-apple-darwin
CLI_ARM="target/aarch64-apple-darwin/release/neo"

if rustup target list --installed | grep -q x86_64-apple-darwin; then
  echo "==> building neo-ffi + CLI (x86_64) and creating universal binaries"
  cargo build -p neo-ffi --features uniffi --release --target x86_64-apple-darwin
  cargo build -p neo-cli --release --target x86_64-apple-darwin
  lipo -create "$FFI_ARM" target/x86_64-apple-darwin/release/libneo_ffi.a \
    -output "$NATIVE_DIR/Libs/libneo_ffi.a"
  lipo -create "$CLI_ARM" target/x86_64-apple-darwin/release/neo \
    -output "$NATIVE_DIR/Bin/neo"
else
  echo "==> x86_64-apple-darwin not installed; shipping arm64-only artifacts"
  cp "$FFI_ARM" "$NATIVE_DIR/Libs/libneo_ffi.a"
  cp "$CLI_ARM" "$NATIVE_DIR/Bin/neo"
fi

echo "==> generating Swift bindings"
"$BINDGEN" generate \
  --library target/aarch64-apple-darwin/release/libneo_ffi.dylib \
  --language swift \
  --out-dir "$NATIVE_DIR/Generated"
mv "$NATIVE_DIR/Generated/neo_ffiFFI.modulemap" "$NATIVE_DIR/Generated/module.modulemap"

echo "==> done:"
ls -la "$NATIVE_DIR/Libs/libneo_ffi.a" "$NATIVE_DIR/Bin/neo" "$NATIVE_DIR/Generated"
