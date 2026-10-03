#!/bin/bash
set -euo pipefail

usage_products_dir="${1:?Usage: scripts/check-codex-usage.sh <DerivedData/Build/Products/Debug>}"
usage_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
usage_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-usage-checks.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
usage_app_dir="$usage_products_dir/Boring Notch.app"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$usage_build_dir/module-cache" \
  "$usage_repo_root/boringNotch/models/CodexUsageModels.swift" \
  "$usage_repo_root/BoringNotchXPCHelper/CodexUsageParser.swift" \
  "$usage_repo_root/BoringNotchXPCHelper/CodexUsageProbe.swift" \
  "$usage_repo_root/Tests/CodexUsageProbeChecks.swift" \
  -o "$usage_build_dir/probe-checks"
"$usage_build_dir/probe-checks" "$usage_repo_root/Tests/Fixtures/codex-usage-server.py"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$usage_build_dir/module-cache" \
  -I "$usage_products_dir" -F "$usage_products_dir" \
  "$usage_repo_root/Tests/CodexUsageRegressionChecks.swift" \
  "$usage_app_dir/Contents/MacOS/Boring Notch.debug.dylib" \
  -Xlinker -rpath -Xlinker "$usage_app_dir/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$usage_app_dir/Contents/Frameworks" \
  -o "$usage_build_dir/manager-checks"
"$usage_build_dir/manager-checks"
