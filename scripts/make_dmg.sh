#!/bin/bash
# Packages build/DataLens.app into build/DataLens-<version>.dmg (drag-to-Applications installer).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
[[ -d build/DataLens.app ]] || ./build.sh
STAGE=$(mktemp -d)
cp -R build/DataLens.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DataLens" -srcfolder "$STAGE" -ov -format UDZO "build/DataLens-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "✓ build/DataLens-$VERSION.dmg"
