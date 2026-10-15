#!/bin/bash
# Packages build/Bassline.app into build/Bassline.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGING=build/dmg
rm -rf "$STAGING" build/Bassline.dmg
mkdir -p "$STAGING"
cp -R build/Bassline.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Bassline" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov build/Bassline.dmg
rm -rf "$STAGING"
echo "Built build/Bassline.dmg"
