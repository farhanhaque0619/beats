#!/bin/bash
# Sourced by the build scripts. `run_xcodebuild <log-name> <xcodebuild args...>` keeps the full
# log in build/<log-name>.log and, on failure, prints every compiler error (deduplicated) last so
# it shows at the end of CI output.
run_xcodebuild() {
  local name="$1"; shift
  mkdir -p build
  local log="build/$name.log"
  if xcodebuild "$@" > "$log" 2>&1; then
    echo "xcodebuild $name: BUILD SUCCEEDED"
    grep -E "^/.*warning: " "$log" | grep -v "/DerivedData/" | sort -u | head -40 || true
    return 0
  fi
  echo "xcodebuild $name: BUILD FAILED"
  echo "----- last 40 lines -----"
  tail -40 "$log"
  echo "----- errors -----"
  grep -E "error:|fatal error|Undefined symbol|ld: " "$log" | sed -E 's|^.*/Ink/|Ink/|' | sort -u | head -150
  return 1
}

# Build settings passed through from the environment when set (CI sets them from repository
# variables): OAuth client IDs and the bundle ID. Unset ones are left to the xcconfig files.
# Fills the OVERRIDES array. (macOS ships bash 3.2: no mapfile, and empty arrays need care
# under `set -u`, hence ${OVERRIDES[@]+"${OVERRIDES[@]}"} at the call sites.)
ink_overrides() {
  OVERRIDES=()
  local v
  for v in INK_GOOGLE_CLIENT_ID INK_MICROSOFT_CLIENT_ID INK_BUNDLE_ID; do
    if [ -n "${!v:-}" ]; then OVERRIDES+=("$v=${!v}"); fi
  done
}
