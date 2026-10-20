#!/usr/bin/env bash
# Run the UI walkthroughs on the simulator; each step saves a screenshot to /tmp/tau-ui.
# Usage: ios/scripts/uitest.sh [testName ...]   e.g. ios/scripts/uitest.sh testAttachmentPicker
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi
only=()
for name in "$@"; do if [[ $name == */* ]]; then only+=("-only-testing:TauUITests/$name"); else only+=("-only-testing:TauUITests/TauUITests/$name"); fi; done
rm -rf /tmp/tau-ui && mkdir -p /tmp/tau-ui
xcodebuild -project Tau.xcodeproj -scheme Tau -destination "platform=iOS Simulator,name=${TAU_SIMULATOR:-iPhone 17 Pro}" \
	-derivedDataPath "${TAU_DERIVED_DATA:-/tmp/tau-dd}" CODE_SIGNING_ALLOWED=NO ${only[@]+"${only[@]}"} test > /tmp/tau-uitest.log 2>&1 || true
grep -E "Test Case .*(passed|failed)|error:" /tmp/tau-uitest.log | sed 's/^.*Test Case/Test Case/' | head -40
ls /tmp/tau-ui
