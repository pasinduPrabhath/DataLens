#!/bin/bash
# Builds, signs with Developer ID, notarizes and staples build/DataLens-<version>.dmg.
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate (Xcode > Settings > Accounts > Manage Certificates).
#   2. xcrun notarytool store-credentials datalens-notary --apple-id <you@example.com> --team-id <TEAMID>
#      (it asks for an app-specific password from appleid.apple.com)
#
# Usage: ./scripts/release.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
PROFILE="${NOTARY_PROFILE:-datalens-notary}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_ID" ]] || { echo "No 'Developer ID Application' certificate found."; exit 1; }
export SIGN_ID

sed -i '' "s|<key>CFBundleShortVersionString</key><string>[^<]*</string>|<key>CFBundleShortVersionString</key><string>$VERSION</string>|" Resources/Info.plist
./build.sh
./scripts/make_dmg.sh "$VERSION"
DMG="build/DataLens-$VERSION.dmg"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "▸ Notarizing (takes a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "✓ Ready to publish: $DMG"
