#!/bin/bash
# Builds a universal (Apple silicon + Intel) Bassline.app into ./build.
# Requires macOS with Xcode 15.3 or later.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Bassline.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
cp "$BIN_DIR/Bassline" "$APP/Contents/MacOS/Bassline"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: render every size macOS asks for from the 1024px master.
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature so macOS can track the app's privacy permissions.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
