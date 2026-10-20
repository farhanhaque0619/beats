#!/bin/bash
# Regenerates Ink.xcodeproj from project.yml. Needs XcodeGen (brew install xcodegen).
# Only needed after changing project.yml: files under App/ are picked up automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml
python3 scripts/fix-project.py Ink.xcodeproj/project.pbxproj
