#!/usr/bin/env bash
# Generate Tau.xcodeproj and build for the iOS simulator. Usage: ios/scripts/build.sh [--run]
#   --run  also install and launch on the "iPhone 17 Pro" simulator (booting it if needed).
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi
derived="${TAU_DERIVED_DATA:-/tmp/tau-dd}"
xcodebuild -project Tau.xcodeproj -scheme Tau -configuration Debug \
	-destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
	CODE_SIGNING_ALLOWED=NO build | tail -n 3
if [ "${1:-}" = "--run" ]; then
	device="${TAU_SIMULATOR:-iPhone 17 Pro}"
	xcrun simctl boot "$device" 2>/dev/null || true
	xcrun simctl install "$device" "$derived/Build/Products/Debug-iphonesimulator/Tau.app"
	xcrun simctl launch --terminate-running-process "$device" dev.tau.app
fi
