#!/usr/bin/env bash
# Run the UI walkthroughs on the simulator; each step saves a screenshot to /tmp/tau-ui.
# Usage: ios/scripts/uitest.sh [testName ...]   e.g. ios/scripts/uitest.sh testAttachmentPicker
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi
only=()
for name in "$@"; do if [[ $name == */* ]]; then only+=("-only-testing:TauUITests/$name"); else only+=("-only-testing:TauUITests/TauUITests/$name"); fi; done
rm -rf /tmp/tau-ui && mkdir -p /tmp/tau-ui
# The servers' tokens, for the tests against this Mac's server and a second one (TAU_SERVER2, an ssh host: set in
# Config/Local.env, see Local.example.env; TauUITests/SendingUITests.swift), and this Mac's name as its Browse row
# shows it.
[ -f Config/Local.env ] && . Config/Local.env
export TEST_RUNNER_TAU_TOKEN=$(cat ~/.config/tau/token 2>/dev/null)
export TEST_RUNNER_TAU_HOSTNAME=$(hostname -s)
if [ -n "${TAU_SERVER2:-}" ]; then
	export TEST_RUNNER_TAU_SERVER2_URL="ws://$TAU_SERVER2:7878"
	export TEST_RUNNER_TAU_SERVER2_TOKEN=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$TAU_SERVER2" 'cat ~/.config/tau/token' 2>/dev/null)
fi
# A runner left from an earlier build can run old steps, or none: build it fresh each time.
rm -rf "${TAU_DERIVED_DATA:-/tmp/tau-dd}"/Build/Products/Debug-iphonesimulator/TauUITests-Runner.app "${TAU_DERIVED_DATA:-/tmp/tau-dd}"/Build/Products/Debug-iphonesimulator/TauUITests.xctest
xcodebuild -project Tau.xcodeproj -scheme Tau -destination "platform=iOS Simulator,name=${TAU_SIMULATOR:-iPhone 17 Pro}" \
	-derivedDataPath "${TAU_DERIVED_DATA:-/tmp/tau-dd}" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= ${only[@]+"${only[@]}"} test > /tmp/tau-uitest.log 2>&1 || true
grep -E "Test Case .*(passed|failed|skipped)|error:" /tmp/tau-uitest.log | sed 's/^.*Test Case/Test Case/' | head -40
ls /tmp/tau-ui
