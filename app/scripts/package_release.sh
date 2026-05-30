#!/usr/bin/env bash
# package_release.sh — build Book2Visual.app from the SwiftPM executable and
# package it as a distributable zip for a GitHub release.
#
# We build with SwiftPM (not XcodeGen) because the package splits the SwiftUI
# code into a Book2VisualCore library + a thin Book2VisualApp executable that
# imports it — SwiftPM links the module correctly, whereas a single-target
# Xcode app would fail on `import Book2VisualCore`.
#
# NOTE ON SIGNING: without an Apple Developer ID this app is only AD-HOC signed.
# Gatekeeper will warn on first launch ("unidentified developer" / "damaged").
# Users must right-click → Open, or run:
#     xattr -dr com.apple.quarantine /Applications/Book2Visual.app
# For a clean, notarized install see the mac-homebrew-deploy workflow.
set -euo pipefail

cd "$(dirname "$0")/.."          # repo/app
APP_NAME="Book2Visual"
VERSION="${1:-1.0.0}"
BUILD_DIR=".build/release"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The executable product is Book2VisualApp; rename to match CFBundleExecutable.
cp "$BUILD_DIR/Book2VisualApp" "$APP/Contents/MacOS/$APP_NAME"
cp "Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle any SwiftPM resource bundles (e.g. fonts) next to the binary.
if compgen -G "$BUILD_DIR/*.bundle" > /dev/null; then
  cp -R "$BUILD_DIR"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
fi

echo "==> Ad-hoc codesign (deep)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "   signature verifies (ad-hoc)"

echo "==> Zipping"
ZIP="$DIST/$APP_NAME-$VERSION-macos.zip"
# ditto preserves the bundle structure + resource forks for a valid .app zip.
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME-$VERSION-macos.zip" )

echo "==> Done"
echo "   app: $APP"
echo "   zip: $ZIP"
ls -lh "$ZIP"
