#!/usr/bin/env bash
# Builds Stash.app with SwiftPM and the Xcode command line tools (macOS 26 SDK).
#
#   scripts/build-app.sh                  # release build into build/Stash.app
#   CONFIG=debug scripts/build-app.sh     # debug build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#   VERSION=1.2.0 scripts/build-app.sh    # stamps CFBundleShortVersionString
#
# Ad-hoc signing works, but macOS then asks for Screen Recording permission again after
# every rebuild. Sign with a real identity (any Apple Development certificate) to keep it.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Stash.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --product Snipper
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Snipper" "$APP/Contents/MacOS/Snipper"
cp App/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp -R Sources/Snipper/Resources/. "$APP/Contents/Resources/"
# Ship the browser extension inside the app so "Show Extension Folder" works.
rsync -a --exclude tests --exclude node_modules --exclude '*.md' Extension/ "$APP/Contents/Resources/ChromeExtension/"

if [ -f App/AppIcon.png ]; then
  echo "▸ Making the app icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size App/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) App/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▸ Signing ($SIGN_IDENTITY)"
# Notarization needs a secure timestamp; ad-hoc signatures cannot have one.
TIMESTAMP="--timestamp=none"
[ "$SIGN_IDENTITY" != "-" ] && TIMESTAMP="--timestamp"
codesign --force --options runtime "$TIMESTAMP" \
  --entitlements App/Snipper.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"

echo "✓ Built $APP"
echo "  Run it with: open $APP"
