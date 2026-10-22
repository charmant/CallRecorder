#!/bin/bash
# Builds dist/CallRecorder-<version>.dmg for GitHub Releases.
# Signed ad-hoc: an Apple Development certificate isn't meant for distribution and would also embed
# the developer's email in the app. Without notarization macOS asks for confirmation on first launch.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
SIGN_IDENTITY="-" ./scripts/build-app.sh

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mv build/CallRecorder.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/CallRecorder-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "CallRecorder $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
