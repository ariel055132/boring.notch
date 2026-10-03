#!/bin/bash
set -euo pipefail

# Build the application's Debug configuration first; test its actual module and dylib.
regression_products_dir="${1:?Usage: scripts/check-concurrency.sh <DerivedData/Build/Products/Debug>}"
regression_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
regression_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-regressions.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
regression_app_dir="$regression_products_dir/Boring Notch.app"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$regression_build_dir/module-cache" \
  -I "$regression_products_dir" -F "$regression_products_dir" \
  "$regression_repo_root/Tests/ConcurrencyRegressionChecks.swift" \
  "$regression_repo_root/Tests/CalendarRegressionChecks.swift" \
  "$regression_repo_root/Tests/XPCRegressionChecks.swift" \
  "$regression_app_dir/Contents/MacOS/Boring Notch.debug.dylib" \
  -Xlinker -rpath -Xlinker "$regression_app_dir/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$regression_app_dir/Contents/Frameworks" \
  -o "$regression_build_dir/checks"
"$regression_build_dir/checks"
