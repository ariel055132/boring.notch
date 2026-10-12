#!/bin/bash
set -euo pipefail

# Offline fixtures only: no real credentials, API requests or Keychain prompts.
claude_products_dir="${1:?Usage: scripts/check-claude-usage.sh <DerivedData/Build/Products/Debug>}"
claude_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
claude_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-claude-checks.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
claude_app_dir="$claude_products_dir/Boring Notch.app"

# Anonymous XPC and standalone probes do not exercise launchd's security session.
# Check the shipped helper, since a separate session silently blocks Keychain UI.
claude_helper_plist="$claude_app_dir/Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/Info.plist"
if [[ "$(/usr/bin/plutil -extract XPCService.JoinExistingSession raw -expect bool -o - "$claude_helper_plist")" != "true" ]]; then
  echo "FAIL: bundled XPC helper must join the app's login session for Claude Keychain access." >&2
  exit 1
fi
echo "PASS: bundled XPC helper joins the app's login session."

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$claude_build_dir/module-cache" \
  "$claude_repo_root/boringNotch/models/ClaudeUsageModels.swift" \
  "$claude_repo_root/BoringNotchXPCHelper/ClaudeUsageParser.swift" \
  "$claude_repo_root/BoringNotchXPCHelper/ClaudeUsageProbe.swift" \
  "$claude_repo_root/Tests/ClaudeUsageProbeChecks.swift" \
  -o "$claude_build_dir/probe-checks"
"$claude_build_dir/probe-checks"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$claude_build_dir/module-cache" \
  -I "$claude_products_dir" -F "$claude_products_dir" \
  "$claude_repo_root/Tests/ClaudeUsageRegressionChecks.swift" \
  "$claude_app_dir/Contents/MacOS/Boring Notch.debug.dylib" \
  -Xlinker -rpath -Xlinker "$claude_app_dir/Contents/MacOS" \
  -Xlinker -rpath -Xlinker "$claude_app_dir/Contents/Frameworks" \
  -o "$claude_build_dir/manager-checks"
"$claude_build_dir/manager-checks"
