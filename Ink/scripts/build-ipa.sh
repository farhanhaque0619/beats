#!/bin/bash
# Builds an unsigned iPhone app and wraps it as build/Ink-unsigned.ipa.
# Sideloading tools (Sideloadly, AltStore) re-sign it with your Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcodebuild-helper.sh
ink_overrides

run_xcodebuild ios-build \
  -project Ink.xcodeproj \
  -scheme Ink-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData-ios \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  ${OVERRIDES[@]+"${OVERRIDES[@]}"} build

rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/DerivedData-ios/Build/Products/Release-iphoneos/Ink.app build/ipa/Payload/
(cd build/ipa && zip -qry ../Ink-unsigned.ipa Payload)
rm -rf build/ipa
echo "Built build/Ink-unsigned.ipa"
