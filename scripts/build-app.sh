#!/bin/bash
# Builds build/CallRecorder.app from the Swift package and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/CallRecorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CallRecorder" "$APP/Contents/MacOS/CallRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The signature must be stable, otherwise macOS forgets granted permissions after every rebuild.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development certificate — signing ad-hoc; permissions will have to be granted after each build."
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Done: $APP (signed: $IDENTITY)"
