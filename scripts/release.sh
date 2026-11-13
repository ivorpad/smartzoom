#!/bin/zsh
# Builds a Developer ID signed SmartZoom.app, packs it into a signed DMG and,
# when NOTARY_PROFILE names a `notarytool store-credentials` profile, notarizes and staples it.
#   TEAM_ID=XXXXXXXXXX [NOTARY_PROFILE=name] scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."
: "${TEAM_ID:?set TEAM_ID to your Apple Developer team ID}"
IDENTITY="Developer ID Application"

xcodegen generate --quiet
rm -rf build/release dist
xcodebuild -project SmartZoom.xcodeproj -scheme SmartZoom -configuration Release \
  -derivedDataPath build/release -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  -quiet build

APP=build/release/Build/Products/Release/SmartZoom.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --verify --strict --deep "$APP"

rm -rf build/dmg && mkdir -p dist build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
DMG="dist/SmartZoom-$VERSION.dmg"
hdiutil create -volname "SmartZoom $VERSION" -srcfolder build/dmg -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
shasum -a 256 "$DMG"
