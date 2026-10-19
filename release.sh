#!/bin/bash
# Builds dist/LightsOut.dmg for a GitHub release (same file name every version, so "latest" download links never break).
#
# Without an Apple Developer account the app is ad-hoc signed: it works, but downloaders must approve it once
# in System Settings > Privacy & Security. With a paid account ($99/yr) set these for a notarized, prompt-free DMG:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=<profile saved with: xcrun notarytool store-credentials>
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

APP=build/LightsOut.app
DMG="dist/LightsOut.dmg"

if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname LightsOut -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "${SIGN_ID:-}" ]; then
  codesign --sign "$SIGN_ID" --timestamp "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "built $DMG (version $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist))"
shasum -a 256 "$DMG"
