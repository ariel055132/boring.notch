#!/bin/bash
set -euo pipefail

weather_products_dir="${1:?Usage: scripts/check-weather.sh <DerivedData/Build/Products/Debug>}"
weather_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
weather_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-weather-checks.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
weather_app_dir="$weather_products_dir/Boring Notch.app"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$weather_build_dir/module-cache" \
  -I "$weather_products_dir" -F "$weather_products_dir" \
  "$weather_repo_root/Tests/WeatherRegressionChecks.swift" \
  "$weather_app_dir/Contents/MacOS/Boring Notch.debug.dylib" \
  -Xlinker -rpath -Xlinker "$weather_app_dir/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$weather_app_dir/Contents/Frameworks" \
  -o "$weather_build_dir/checks"
"$weather_build_dir/checks"
