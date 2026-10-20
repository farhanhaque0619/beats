#!/bin/bash
# Builds Ink with your Apple team and installs it on your iPhone (cable or paired over Wi-Fi).
# With a free Apple ID the install expires after 7 days; run this again to renew it. Your
# accounts and settings survive reinstalls.
#
#   ./scripts/install-iphone.sh                 # first connected iPhone
#   ./scripts/install-iphone.sh "Farhan's iPhone"
#
# One-time setup: Xcode › Settings › Apple Accounts (sign in), DEVELOPMENT_TEAM in
# Config/Local.xcconfig, Developer Mode on the iPhone. See docs/INSTALL.md.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcodebuild-helper.sh

if ! grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' Config/Local.xcconfig 2>/dev/null; then
  echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig first (copy Config/Local.xcconfig.example)."
  echo "Your team ID: Xcode › Settings › Apple Accounts › your Apple ID › Personal Team."
  exit 1
fi

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and conn.get("tunnelState") in ("connected", "available", None) and hw.get("reality") != "virtual":
        print(d.get("identifier", ""))
        break
PY
)
  rm -f "$JSON"
fi
if [ -z "$DEVICE" ]; then
  echo "No iPhone found. Plug it in, unlock it and tap Trust, or pass its name: $0 \"My iPhone\""
  exit 1
fi

echo "Building Ink for $DEVICE…"
run_xcodebuild device-build \
  -project Ink.xcodeproj \
  -scheme Ink-iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData-device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build

APP=build/DerivedData-device/Build/Products/Release-iphoneos/Ink.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
echo "Installing $BUNDLE_ID…"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "Done. Ink is on your iPhone (renew within 7 days if you use a free Apple ID)."
