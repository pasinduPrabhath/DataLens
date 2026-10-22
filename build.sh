#!/bin/bash
# Builds DataLens.app into ./build and (optionally) installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DataLens.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compiling universal (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DataLens" "$APP/Contents/MacOS/DataLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Generating icon…"
swift scripts/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - -r="designated => identifier \"dev.pasindu.DataLens\"" "$APP"

echo "✓ Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/DataLens.app
  cp -R "$APP" /Applications/DataLens.app
  echo "✓ Installed to /Applications/DataLens.app"
fi
