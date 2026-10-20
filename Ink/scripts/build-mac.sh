#!/bin/bash
# Builds a universal (Apple silicon + Intel), ad-hoc signed Ink.app into Ink/build.
# Requires macOS with Xcode 26 or later.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcodebuild-helper.sh
ink_overrides

rm -rf build/Ink.app
run_xcodebuild mac-build \
  -project Ink.xcodeproj \
  -scheme Ink-macOS \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ${OVERRIDES[@]+"${OVERRIDES[@]}"} build

cp -R build/DerivedData/Build/Products/Release/Ink.app build/Ink.app
codesign --verify --verbose build/Ink.app
codesign -d --entitlements - build/Ink.app 2>/dev/null | head -20 || true
lipo -info build/Ink.app/Contents/MacOS/Ink
echo "Built build/Ink.app"
