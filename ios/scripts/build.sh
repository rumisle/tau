#!/usr/bin/env bash
# Generate Tau.xcodeproj and build. Usage:
#   ios/scripts/build.sh            build for the simulator
#   ios/scripts/build.sh --run      ...and install and launch on the "iPhone 17 Pro" simulator
#   ios/scripts/build.sh --device   build signed for a connected iPhone, install and launch it
#                                   (the team from Config/Local.xcconfig, or TAU_TEAM; TAU_DEVICE: device name or id)
# Signing makes profiles with the Apple ID in Xcode's Accounts, or, without one, with an App Store Connect API key:
# ~/.config/tau/asc_AuthKey_<key id>.p8 (owner-only) and its issuer ID in ~/.config/tau/asc_issuer.
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi
derived="${TAU_DERIVED_DATA:-/tmp/tau-dd}"
. scripts/config.sh

if [ "${1:-}" = "--device" ]; then
	[ -n "$team" ] || { echo "no signing team: set DEVELOPMENT_TEAM in ios/Config/Local.xcconfig (see Local.example.xcconfig)" >&2; exit 1; }
	# The extensions (the Live Activity, the share sheet) need provisioning profiles of their own, which only an Apple ID signed in
	# to Xcode (Settings > Accounts) can make; without one the app is built for the device without it.
	profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
	auth=()
	asc_key=$(ls "$HOME"/.config/tau/asc_AuthKey_*.p8 2>/dev/null | head -n 1 || true)
	if [ -n "$asc_key" ] && [ -s "$HOME/.config/tau/asc_issuer" ]; then
		asc_id=$(basename "$asc_key" .p8); asc_id=${asc_id#asc_AuthKey_}
		auth=(-authenticationKeyPath "$asc_key" -authenticationKeyID "$asc_id" -authenticationKeyIssuerID "$(tr -d '[:space:]' < "$HOME/.config/tau/asc_issuer")")
	fi
	if [ ${#auth[@]} -eq 0 ] && ! grep -rlqa "$team.$bundle.widgets" "$profiles" 2>/dev/null && ! defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -q identifier; then
		echo "no Xcode account to sign the Live Activity extension: building without it" >&2
		sed -e '/^  TauWidgets:/,/^  TauUITests:/{/^  TauUITests:/!d;}' -e '/      - target: TauWidgets/d' -e '/      - target: TauShare/d' -e '/      - target: TauNotifications/d' -e '/CODE_SIGN_ENTITLEMENTS: Tau\/Tau.entitlements/d' project.yml > .project-device.yml
		if command -v xcodegen >/dev/null; then xcodegen generate --quiet --spec .project-device.yml; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet --spec .project-device.yml; fi
		rm -f .project-device.yml
	fi
	device="${TAU_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ {print $3; exit}')}"
	[ -n "$device" ] || { echo "no paired device available" >&2; exit 1; }
	xcodebuild -project Tau.xcodeproj -scheme Tau -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath "$derived-device" \
		-allowProvisioningUpdates ${auth[@]+"${auth[@]}"} DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic build > /tmp/tau-build-device.log 2>&1 || { grep -E "error:" /tmp/tau-build-device.log; exit 1; }
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
