#!/bin/bash
# Packages build/Ink.app into build/Ink.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGING=build/dmg
rm -rf "$STAGING" build/Ink.dmg
mkdir -p "$STAGING"
cp -R build/Ink.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Ink" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov build/Ink.dmg
rm -rf "$STAGING"
echo "Built build/Ink.dmg"
