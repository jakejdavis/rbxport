#!/bin/bash
# Release build -> macos/dist/rbxport.app -> macos/dist/rbxport-<version>.dmg
#
# Usage: package.sh
# Signing uses the project's automatic signing (the personal team in project.yml).
# Notarization is optional: set NOTARY_PROFILE to a `xcrun notarytool store-credentials`
# keychain profile and the DMG is submitted, waited on and stapled; unset, it is skipped.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MACOS="$(cd "$HERE/.." && pwd)"
DIST="$MACOS/dist"
DERIVED="$MACOS/build-release"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

cd "$MACOS"
# build-rust.sh must have run once before xcodegen (the project references its output).
"$HERE/build-rust.sh" release
xcodegen generate

# Configuration Release runs build-rust.sh release as a pre-build phase.
xcodebuild -scheme rbxport -configuration Release -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build

APP_SRC="$DERIVED/Build/Products/Release/rbxport.app"
[ -d "$APP_SRC" ] || { echo "package: no app at $APP_SRC" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist" 2>/dev/null || echo 0)"
DMG="$DIST/rbxport-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$APP_SRC" "$DIST/rbxport.app"

# The DMG holds the app and an Applications shortcut.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rbxport-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$DIST/rbxport.app" "$STAGE/rbxport.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "rbxport" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "package: $DMG ($(du -h "$DMG" | cut -f1))"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "package: notarizing with profile $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "package: NOTARY_PROFILE not set, skipping notarization"
fi
