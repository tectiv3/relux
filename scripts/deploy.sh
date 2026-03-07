#!/bin/bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
APP_NAME="Relux"
SCHEME="Relux"
BUNDLE_ID="com.relux.app"
IDENTITY="Developer ID Application"  # will match any Developer ID cert
TEAM_ID="${RELUX_TEAM_ID:?Set RELUX_TEAM_ID env var to your Apple team ID}"
APPLE_ID="${RELUX_APPLE_ID:?Set RELUX_APPLE_ID env var to your Apple ID email}"
APP_PASSWORD="${RELUX_APP_PASSWORD:?Set RELUX_APP_PASSWORD env var (app-specific password from appleid.apple.com)}"
HOMEBREW_TAP="$HOME/code/homebrew-relux"

GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$GIT_TAG" ]; then
  echo "ERROR: No git tag found. Tag a release first: git tag 1.0.0"
  exit 1
fi
VERSION="${GIT_TAG#v}"
BUILD_DIR="build/release"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

# ── Clean ────────────────────────────────────────────────────────────
echo "==> Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Archive ──────────────────────────────────────────────────────────
echo "==> Archiving $SCHEME (v$VERSION)"
xcodebuild archive \
  -scheme "$SCHEME" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  MARKETING_VERSION="$VERSION" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | tail -1

# ── Export ───────────────────────────────────────────────────────────
echo "==> Exporting archive"

EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | tail -1

APP_PATH="$EXPORT_PATH/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: $APP_PATH not found after export"
  exit 1
fi

# ── Create DMG ───────────────────────────────────────────────────────
echo "==> Creating DMG"

DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING"

# ── Notarize ─────────────────────────────────────────────────────────
echo "==> Submitting for notarization (this may take a few minutes)"

xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait || { echo "Notarization failed. Run: xcrun notarytool log <id> --apple-id \$RELUX_APPLE_ID --team-id \$RELUX_TEAM_ID --password \$RELUX_APP_PASSWORD"; exit 1; }

# ── Staple ───────────────────────────────────────────────────────────
echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

# ── GitHub Release ────────────────────────────────────────────────────
if command -v gh &>/dev/null; then
  echo "==> Creating GitHub release and uploading DMG"
  gh release create "$GIT_TAG" "$DMG_PATH" \
    --title "Relux $VERSION" \
    --generate-notes
else
  echo "==> Opening GitHub release page — attach the DMG manually"
  open "https://github.com/tectiv3/relux/releases/new?tag=$GIT_TAG&title=Relux+$VERSION"
fi

# ── Update Homebrew tap ──────────────────────────────────────────────
echo "==> Updating Homebrew cask"

DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
CASK_FILE="$HOMEBREW_TAP/Casks/relux.rb"

sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$CASK_FILE"
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" "$CASK_FILE"

git -C "$HOMEBREW_TAP" add -A
git -C "$HOMEBREW_TAP" commit -m "Update Relux to $VERSION"
git -C "$HOMEBREW_TAP" push

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo "Done! Notarized DMG: $DMG_PATH"
echo "  Version: $VERSION"
echo "  SHA256:  $DMG_SHA"
echo "  Release: https://github.com/tectiv3/relux/releases/tag/$GIT_TAG"
