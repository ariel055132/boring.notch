#!/bin/bash
set -euo pipefail
battery_root="$(cd "$(dirname "$0")/.." && pwd)"
battery_checks="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-battery-checks.XXXXXX")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" -module-cache-path "$battery_checks/modules" \
    "$battery_root/boringNotch/models/DeviceBatteryModels.swift" \
    "$battery_root/BoringNotchXPCHelper/DeviceBatteryProcess.swift" \
    "$battery_root/BoringNotchXPCHelper/AirPodsBatteryReader.swift" \
    "$battery_root/BoringNotchXPCHelper/DeviceBatteryProbe.swift" \
    "$battery_root/Tests/DeviceBatteryProbeChecks.swift" -o "$battery_checks/readers"
"$battery_checks/readers"
if [ "$#" -gt 0 ]; then
    battery_products="$1"
    battery_app="$battery_products/Boring Notch.app"
    xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
        -target "$(uname -m)-apple-macos14.0" -module-cache-path "$battery_checks/modules" \
        -I "$battery_products" -F "$battery_products" \
        "$battery_root/Tests/DeviceBatteryRegressionChecks.swift" \
        "$battery_app/Contents/MacOS/Boring Notch.debug.dylib" \
        -Xlinker -rpath -Xlinker "$battery_app/Contents/MacOS" \
        -Xlinker -rpath -Xlinker "$battery_app/Contents/Frameworks" -o "$battery_checks/manager"
    "$battery_checks/manager"
fi
