#!/bin/bash
# Builds the app and packages release assets into ./dist:
#   SpaceKeeper-<version>.zip   (what most people download)
#   SpaceKeeper-<version>.dmg   (drag-to-Applications disk image)
#   SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
APP="build/SpaceKeeper.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
rm -rf dist && mkdir -p dist

ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/SpaceKeeper-$VERSION.zip"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SpaceKeeper" -srcfolder "$STAGE" -ov -format UDZO "dist/SpaceKeeper-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

( cd dist && shasum -a 256 SpaceKeeper-"$VERSION".zip SpaceKeeper-"$VERSION".dmg > SHA256SUMS.txt )
echo "Packaged:"; ls -lh dist
