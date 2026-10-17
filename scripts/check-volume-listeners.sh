#!/bin/bash
set -euo pipefail

# Compile the production manager against a fake CoreAudio boundary. Notifications
# originate on a background queue; no audio devices or system volume are changed.
volume_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
volume_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/boring-notch-volume-checks.XXXXXX")"
volume_source="${VOLUME_MANAGER_SOURCE:-$volume_repo_root/boringNotch/managers/VolumeManager.swift}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun clang -fblocks -Wall -Werror -mmacosx-version-min=14.0 \
  -c "$volume_repo_root/Tests/Fixtures/VolumeListenerFixture.c" \
  -o "$volume_build_dir/audio-fixture.o"

for volume_optimization in -Onone -O; do
  xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -parse-as-library -target "$(uname -m)-apple-macos14.0" "$volume_optimization" \
    -module-cache-path "$volume_build_dir/module-cache" \
    -import-objc-header "$volume_repo_root/Tests/Fixtures/VolumeListenerFixture.h" \
    "$volume_source" "$volume_repo_root/Tests/VolumeListenerRegressionChecks.swift" \
    "$volume_build_dir/audio-fixture.o" \
    -o "$volume_build_dir/volume-listener-checks"
  echo "Volume listener checks ($volume_optimization)"
  "$volume_build_dir/volume-listener-checks" master
  "$volume_build_dir/volume-listener-checks" channels
done
