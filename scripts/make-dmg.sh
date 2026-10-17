#!/bin/bash
# Packages build/Overdrive.app into build/Overdrive.dmg with an Applications shortcut.
#
# The DMG also carries a hidden copy named Bassline.app: version 1.x (when the app was
# called Bassline) updates itself by copying exactly that name out of the DMG. On first
# launch that copy renames itself to Overdrive.app.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGING=build/dmg
rm -rf "$STAGING" build/Overdrive.dmg
mkdir -p "$STAGING"
cp -R build/Overdrive.app "$STAGING/"
cp -R build/Overdrive.app "$STAGING/Bassline.app"
chflags hidden "$STAGING/Bassline.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Overdrive" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov build/Overdrive.dmg
rm -rf "$STAGING"
echo "Built build/Overdrive.dmg"
