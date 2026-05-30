#!/usr/bin/env bash
# release.sh — one-command signed + notarized + stapled release of Book2Visual,
# published to a GitHub release and wired into the Homebrew cask.
#
# This is the PRODUCTION distribution path (clean first launch, no Gatekeeper
# warning). It extends scripts/package_release.sh (which only ad-hoc signs) by:
#   1. building via SwiftPM and hand-assembling Book2Visual.app
#   2. codesigning with a Developer ID Application cert + hardened runtime +
#      the app's sandbox entitlements (--timestamp, --options runtime)
#   3. zipping with ditto, submitting to Apple notarytool, WAITING + checking
#      the result is "Accepted", then stapling the ticket into the .app
#   4. RE-zipping (the staple ticket lives inside the .app and must be in the
#      distributed zip), computing sha256, creating/updating the GitHub release
#   5. patching version + sha256 into the Homebrew cask
#
# SECRETS: never hardcoded here. Provide them via env vars or a gitignored
# .env.release at the repo root (app/../.env.release). Required:
#   DEVELOPER_ID   e.g. "Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID        e.g. "PVRL9W627Q"
#   AC_PROFILE     notarytool keychain profile name created once via:
#                    xcrun notarytool store-credentials <AC_PROFILE> \
#                      --apple-id you@example.com --team-id TEAMID \
#                      --password <app-specific-password>
# Optional:
#   GH_REPO        default "templegit9/book2visual"
#   CASK_FILE      default "<repo>/Casks/book2visual.rb"
#   TAP_CASK_FILE  if set, the cask in your separate tap clone is patched too,
#                  committed and pushed (e.g. ~/code/homebrew-tap/Casks/book2visual.rb)
#
# Usage:  app/scripts/release.sh <version>      e.g.  app/scripts/release.sh 1.0.1
set -euo pipefail

# ---- locate repo paths -------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # app/scripts
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                       # app
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"                         # repo root

# ---- load secrets from .env.release if present (never committed) --------------
if [[ -f "$REPO_DIR/.env.release" ]]; then
  echo "==> Loading secrets from .env.release"
  # shellcheck disable=SC1090
  set -a; source "$REPO_DIR/.env.release"; set +a
fi

# ---- args + config -----------------------------------------------------------
VERSION="${1:?usage: release.sh <version>   (e.g. 1.0.1)}"
APP_NAME="Book2Visual"
BUNDLE_ID="com.book2visual.app"
GH_REPO="${GH_REPO:-templegit9/book2visual}"
CASK_FILE="${CASK_FILE:-$REPO_DIR/Casks/book2visual.rb}"
ENTITLEMENTS="$APP_DIR/Support/Book2Visual.entitlements"

BUILD_DIR="$APP_DIR/.build/release"
DIST="$APP_DIR/dist"
APP="$DIST/$APP_NAME.app"
EXEC="$APP/Contents/MacOS/$APP_NAME"
ZIP="$DIST/$APP_NAME-$VERSION-macos.zip"
ASSET_NAME="$APP_NAME-$VERSION-macos.zip"
TAG="v$VERSION"
DL_URL="https://github.com/$GH_REPO/releases/download/$TAG/$ASSET_NAME"

# ---- validate prerequisites (fail fast, before the slow steps) ---------------
: "${DEVELOPER_ID:?set DEVELOPER_ID (e.g. \"Developer ID Application: Name (TEAMID)\") in env or .env.release}"
: "${TEAM_ID:?set TEAM_ID (e.g. PVRL9W627Q) in env or .env.release}"
: "${AC_PROFILE:?set AC_PROFILE (notarytool keychain profile name) in env or .env.release}"

echo "==> Verifying Developer ID cert is installed"
if ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
  echo "ERROR: cert not found in keychain: $DEVELOPER_ID" >&2
  echo "       run: security find-identity -v -p codesigning" >&2
  exit 1
fi
command -v gh >/dev/null || { echo "ERROR: gh CLI not installed" >&2; exit 1; }
[[ -f "$ENTITLEMENTS" ]] || { echo "ERROR: entitlements missing: $ENTITLEMENTS" >&2; exit 1; }

echo "==> Releasing $APP_NAME $VERSION (tag $TAG) to $GH_REPO"

# ---- 1. build ----------------------------------------------------------------
echo "==> swift build -c release"
( cd "$APP_DIR" && swift build -c release )

# ---- 2. assemble the .app bundle (concrete Info.plist) -----------------------
echo "==> Assembling $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$EXEC" 2>/dev/null || cp "$BUILD_DIR/Book2VisualApp" "$EXEC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>Book2Visual</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle any SwiftPM resource bundles (e.g. fonts) next to the binary.
if compgen -G "$BUILD_DIR/*.bundle" > /dev/null; then
  cp -R "$BUILD_DIR"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
fi

# ---- 3. codesign Developer ID + hardened runtime + entitlements --------------
# Sign inner resource bundles first (if any), then the executable WITH the
# sandbox entitlements, then the outer bundle. We avoid the deprecated/flaky
# --deep and sign explicitly so the entitlements land on the main executable.
echo "==> Codesigning with Developer ID + hardened runtime"
if compgen -G "$APP/Contents/Resources/*.bundle" > /dev/null; then
  for b in "$APP"/Contents/Resources/*.bundle; do
    codesign --force --timestamp --options runtime \
      --sign "$DEVELOPER_ID" "$b"
  done
fi
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$EXEC"
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$APP"

echo "==> Verifying signature (strict)"
codesign --verify --deep --strict --verbose=2 "$APP"
# Gatekeeper's own assessment; informational pre-notarization (will say
# "rejected" until the ticket is stapled — that's expected at this stage).
spctl -a -vv --type execute "$APP" 2>&1 || true

# ---- 4. zip (pre-notarization) -----------------------------------------------
echo "==> Zipping for notarization"
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ASSET_NAME" )

# ---- 5. notarize + WAIT + check Accepted -------------------------------------
echo "==> Submitting to Apple notary service (this can take several minutes)"
SUBMIT_JSON="$(xcrun notarytool submit "$ZIP" \
  --keychain-profile "$AC_PROFILE" \
  --wait --output-format json)"
echo "$SUBMIT_JSON"
SUBMIT_ID="$(printf '%s' "$SUBMIT_JSON" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))')"
STATUS="$(printf '%s' "$SUBMIT_JSON" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "ERROR: notarization status = '$STATUS' (expected Accepted)" >&2
  if [[ -n "$SUBMIT_ID" ]]; then
    echo "==> Fetching Apple's rejection log:" >&2
    xcrun notarytool log "$SUBMIT_ID" --keychain-profile "$AC_PROFILE" >&2 || true
  fi
  exit 1
fi
echo "==> Notarization Accepted (id $SUBMIT_ID)"

# ---- 6. staple + validate ----------------------------------------------------
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# Now Gatekeeper should accept it offline.
spctl -a -vv --type execute "$APP"

# ---- 7. RE-zip AFTER stapling (ticket must be in the distributed zip) ---------
echo "==> Re-zipping stapled app"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ASSET_NAME" )

# ---- 8. sha256 ---------------------------------------------------------------
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256: $SHA256"

# ---- 9. GitHub release (idempotent) ------------------------------------------
echo "==> Publishing GitHub release $TAG"
if gh release view "$TAG" -R "$GH_REPO" >/dev/null 2>&1; then
  echo "    release $TAG exists — clobbering asset"
  gh release upload "$TAG" "$ZIP" -R "$GH_REPO" --clobber
else
  gh release create "$TAG" "$ZIP" -R "$GH_REPO" \
    --title "$APP_NAME $TAG (macOS)" \
    --notes "Signed (Developer ID) + notarized + stapled. Install: brew install --cask templegit9/tap/book2visual"
fi

# ---- 10. patch the cask ------------------------------------------------------
patch_cask() {
  local file="$1"
  [[ -f "$file" ]] || { echo "    (skip, not found: $file)"; return 0; }
  # Replace the version "..." and sha256 "..." lines in place.
  /usr/bin/sed -i '' -E "s|^( *version )\"[^\"]*\"|\\1\"$VERSION\"|" "$file"
  /usr/bin/sed -i '' -E "s|^( *sha256 )\"[^\"]*\"|\\1\"$SHA256\"|" "$file"
  echo "    patched $file -> version $VERSION, sha256 $SHA256"
}

echo "==> Patching cask in this repo"
patch_cask "$CASK_FILE"

if [[ -n "${TAP_CASK_FILE:-}" ]]; then
  echo "==> Patching + pushing cask in tap repo"
  patch_cask "$TAP_CASK_FILE"
  TAP_DIR="$(cd "$(dirname "$TAP_CASK_FILE")/.." && pwd)"
  ( cd "$TAP_DIR" \
    && git add "$(basename "$(dirname "$TAP_CASK_FILE")")/$(basename "$TAP_CASK_FILE")" \
    && git commit -m "book2visual $VERSION" \
    && git push )
fi

echo
echo "==> DONE: $APP_NAME $VERSION released."
echo "    asset:  $DL_URL"
echo "    sha256: $SHA256"
echo
echo "Next, if your tap cask wasn't auto-pushed (TAP_CASK_FILE unset):"
echo "  cp \"$CASK_FILE\" <tap-clone>/Casks/book2visual.rb"
echo "  ( cd <tap-clone> && git add Casks/book2visual.rb && git commit -m 'book2visual $VERSION' && git push )"
echo
echo "Install with:  brew install --cask templegit9/tap/book2visual"
