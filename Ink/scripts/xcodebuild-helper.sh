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
