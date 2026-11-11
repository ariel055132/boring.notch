#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--run" ]]; then
  echo "Usage: bash scripts/check-claude-renewal-live.sh --run"
  echo "Opt-in: uses your existing Claude login and may renew it through Claude Code; no model prompt is sent."
  exit 0
fi
renewal_root="$(cd "$(dirname "$0")/.." && pwd)"
renewal_build="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-renewal-live.XXXXXX")"
trap 'rm -rf "$renewal_build"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -module-cache-path "$renewal_build/modules" \
  "$renewal_root/boringNotch/models/ClaudeUsageModels.swift" \
  "$renewal_root/BoringNotchXPCHelper/ClaudeUsageParser.swift" \
  "$renewal_root/BoringNotchXPCHelper/ClaudeUsageProbe.swift" \
  "$renewal_root/BoringNotchXPCHelper/ClaudeUsageRenewal.swift" \
  "$renewal_root/BoringNotchXPCHelper/ClaudeUsageSecurityPreflight.swift" \
  "$renewal_root/BoringNotchXPCHelper/ClaudeUsageSecurityCommand.swift" \
  "$renewal_root/Tests/ClaudeUsageRenewalLiveCheck.swift" \
  -o "$renewal_build/check"
"$renewal_build/check" --run
