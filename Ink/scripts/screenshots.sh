#!/bin/bash
# Builds Ink for the iOS Simulator, launches each demo scene and saves screenshots to
# build/screenshots. The app shows a deterministic demo state when launched with
# `-InkScreenshot <scene>`.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcodebuild-helper.sh
ink_overrides
mkdir -p build/screenshots

BUNDLE_ID=$(xcodebuild -project Ink.xcodeproj -scheme Ink-iOS -showBuildSettings 2>/dev/null | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER =/{print $2; exit}')
echo "Bundle ID: $BUNDLE_ID"

run_xcodebuild sim-build \
  -project Ink.xcodeproj \
  -scheme Ink-iOS \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData-sim \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  ${OVERRIDES[@]+"${OVERRIDES[@]}"} build
APP=build/DerivedData-sim/Build/Products/Release-iphonesimulator/Ink.app

# Newest "iPhone NN Pro" simulator available, else any iPhone.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        name = d["name"]
        m = re.match(r"iPhone (\d+) Pro$", name)
        score = (int(m.group(1)) if m else 0, runtime)
        if name.startswith("iPhone") and (best is None or score > best[0]):
            best = (score, d["udid"], name, runtime)
print(best[1])
sys.stderr.write("Simulator: %s (%s)\n" % (best[2], best[3]))
')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"

SCENES=${SCENES:-"welcome inbox swipe thread compose search settings snooze"}
for appearance in dark light; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for scene in $SCENES; do
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -InkScreenshot "$scene" >/dev/null
    sleep "${SETTLE:-5}"
    xcrun simctl io "$UDID" screenshot "build/screenshots/iphone-$scene-$appearance.png" >/dev/null
    echo "Captured $scene ($appearance)"
  done
done
xcrun simctl terminate "$UDID" "$BUNDLE_ID" || true

# Mac: launch the built app on a demo scene and capture the screen.
if [ -d build/Ink.app ]; then
  for scene in ${MAC_SCENES:-"mac-inbox"}; do
    open -n build/Ink.app --args -InkScreenshot "$scene" -ApplePersistenceIgnoreState YES
    sleep 8
    osascript -e 'tell application "Ink" to activate' 2>/dev/null || true
    sleep 1
    if WID=$(swift scripts/window-id.swift Ink 2>/dev/null); then
      screencapture -x -o -l "$WID" "build/screenshots/$scene.png" || echo "screencapture failed for $scene"
    else
      screencapture -x "build/screenshots/$scene.png" || echo "screencapture failed for $scene"
    fi
    osascript -e 'quit app "Ink"' 2>/dev/null || pkill -x Ink || true
    sleep 2
  done
fi
ls -la build/screenshots
