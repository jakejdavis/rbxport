#!/bin/bash
# Builds rbl-ffi, generates the Swift bindings and packages an XCFramework.
# Usage: build-rust.sh [debug|release]
set -euo pipefail

PROFILE="${1:-debug}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/macos/Generated"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

# Xcode runs script phases with a minimal PATH.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

FLAGS=()
DIR=debug
if [ "$PROFILE" = "release" ]; then FLAGS+=(--release); DIR=release; fi

cd "$ROOT"
cargo build -p rbl-ffi ${FLAGS[@]+"${FLAGS[@]}"}
cargo build -p rbl-ffi --features cli --bin uniffi-bindgen ${FLAGS[@]+"${FLAGS[@]}"}

LIB="$TARGET_DIR/$DIR/librbl_ffi.a"
STAMP="$OUT/.stamp-$PROFILE"
# Keep Xcode's inputs stable: only regenerate when the library actually changed.
if [ -f "$STAMP" ] && [ -d "$OUT/rbl_ffi.xcframework" ] && [ ! "$LIB" -nt "$STAMP" ]; then
  echo "rbl-ffi ($PROFILE): bindings up to date"
  exit 0
fi
rm -rf "$OUT/swift" "$OUT/headers" "$OUT/rbl_ffi.xcframework"
mkdir -p "$OUT/swift" "$OUT/headers"

"$TARGET_DIR/$DIR/uniffi-bindgen" generate --library "$LIB" --language swift --out-dir "$OUT/swift"

# Header + modulemap go in the framework's headers; the .swift stays a source.
cp "$OUT/swift/rbl_ffiFFI.h" "$OUT/headers/"
cp "$OUT/swift/rbl_ffiFFI.modulemap" "$OUT/headers/module.modulemap"
rm "$OUT/swift/rbl_ffiFFI.h" "$OUT/swift/rbl_ffiFFI.modulemap"

xcodebuild -create-xcframework -library "$LIB" -headers "$OUT/headers" \
  -output "$OUT/rbl_ffi.xcframework" >/dev/null
touch "$STAMP"
echo "rbl-ffi ($PROFILE): bindings and XCFramework in $OUT"
