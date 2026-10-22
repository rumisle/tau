#!/usr/bin/env bash
# Generate Tau.xcodeproj and build. Usage:
#   ios/scripts/build.sh            build for the simulator
#   ios/scripts/build.sh --run      ...and install and launch on the "iPhone 17 Pro" simulator
#   ios/scripts/build.sh --device   build signed for a connected iPhone, install and launch it
#                                   (TAU_TEAM: signing team, default TEAMID; TAU_DEVICE: device name or id)
set -euo pipefail
cd "$(dirname "$0")/.."
# Aqua Voice's sign-in from this Mac, for dictation (gitignored; see the script).
command -v uv >/dev/null && uv run --quiet scripts/aqua_secrets.py || true
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi
derived="${TAU_DERIVED_DATA:-/tmp/tau-dd}"
bundle=com.rumisle.tau

if [ "${1:-}" = "--device" ]; then
	team="${TAU_TEAM:-TEAMID}"
	# The extensions (the Live Activity, the share sheet) need provisioning profiles of their own, which only an Apple ID signed in
	# to Xcode (Settings > Accounts) can make; without one the app is built for the device without it.
	profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
	if ! grep -rlqa "$team.$bundle.widgets" "$profiles" 2>/dev/null && ! defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -q identifier; then
		echo "no Xcode account to sign the Live Activity extension: building without it" >&2
		sed -e '/^  TauWidgets:/,/^  TauUITests:/{/^  TauUITests:/!d;}' -e '/      - target: TauWidgets/d' -e '/      - target: TauShare/d' -e '/CODE_SIGN_ENTITLEMENTS: Tau\/Tau.entitlements/d' project.yml > .project-device.yml
		if command -v xcodegen >/dev/null; then xcodegen generate --quiet --spec .project-device.yml; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet --spec .project-device.yml; fi
		rm -f .project-device.yml
	fi
	device="${TAU_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ {print $3; exit}')}"
	[ -n "$device" ] || { echo "no paired device available" >&2; exit 1; }
	xcodebuild -project Tau.xcodeproj -scheme Tau -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath "$derived-device" \
		-allowProvisioningUpdates DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic build > /tmp/tau-build-device.log 2>&1 || { grep -E "error:" /tmp/tau-build-device.log; exit 1; }
	xcrun devicectl device install app --device "$device" "$derived-device/Build/Products/Release-iphoneos/Tau.app"
	xcrun devicectl device process launch --device "$device" "$bundle" || echo "installed; launch it from the home screen"
	exit 0
fi

xcodebuild -project Tau.xcodeproj -scheme Tau -configuration Debug \
	-destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
	CODE_SIGNING_ALLOWED=NO build > /tmp/tau-build.log 2>&1 || { grep -E "error:" /tmp/tau-build.log; exit 1; }
echo "build succeeded"
if [ "${1:-}" = "--run" ]; then
	device="${TAU_SIMULATOR:-iPhone 17 Pro}"
	xcrun simctl boot "$device" 2>/dev/null || true
	xcrun simctl install "$device" "$derived/Build/Products/Debug-iphonesimulator/Tau.app"
	xcrun simctl launch --terminate-running-process "$device" "$bundle"
fi
