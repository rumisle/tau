#!/usr/bin/env bash
# Archive tau and upload it to App Store Connect ("tau agent"), for TestFlight. Usage: ios/scripts/testflight.sh
# Signs with the App Store Connect API key (~/.config/tau/asc_AuthKey_<key id>.p8, its issuer ID in
# ~/.config/tau/asc_issuer): Apple Distribution, profiles made as needed. The build number is the time, so each
# upload is later than the last. Logs: /tmp/tau-archive.log, /tmp/tau-upload.log.
set -euo pipefail
cd "$(dirname "$0")/.."
# Xcode's packaging runs /usr/bin/rsync, which starts the rsync first on PATH as its other end: a newer one (nix's,
# Homebrew's) refuses its options ("Copy failed").
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
. scripts/config.sh
[ -n "$team" ] || { echo "no signing team: set DEVELOPMENT_TEAM in ios/Config/Local.xcconfig (see Local.example.xcconfig)" >&2; exit 1; }
asc_key=$(ls "$HOME"/.config/tau/asc_AuthKey_*.p8 2>/dev/null | head -n 1 || true)
[ -n "$asc_key" ] && [ -s "$HOME/.config/tau/asc_issuer" ] || { echo "no App Store Connect API key in ~/.config/tau" >&2; exit 1; }
asc_id=$(basename "$asc_key" .p8); asc_id=${asc_id#asc_AuthKey_}
auth=(-allowProvisioningUpdates -authenticationKeyPath "$asc_key" -authenticationKeyID "$asc_id" -authenticationKeyIssuerID "$(tr -d '[:space:]' < "$HOME/.config/tau/asc_issuer")")
build=$(date -u +%y%m%d.%H%M)
work=/tmp/tau-testflight
rm -rf "$work" && mkdir -p "$work"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; else nix shell nixpkgs#xcodegen -c xcodegen generate --quiet; fi

echo "archiving build $build"
xcodebuild -project Tau.xcodeproj -scheme Tau -configuration Release -destination 'generic/platform=iOS' \
	-derivedDataPath /tmp/tau-dd-archive -archivePath "$work/Tau.xcarchive" "${auth[@]}" \
	DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$build" archive > /tmp/tau-archive.log 2>&1 \
	|| { grep -E "error:" /tmp/tau-archive.log | sort -u; exit 1; }

cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
echo "uploading"
xcodebuild -exportArchive -archivePath "$work/Tau.xcarchive" -exportOptionsPlist "$work/export.plist" \
	-exportPath "$work/export" "${auth[@]}" > /tmp/tau-upload.log 2>&1 \
	|| { grep -E "error|Error" /tmp/tau-upload.log | sort -u | head -20; exit 1; }
echo "uploaded build $build: in TestFlight once App Store Connect has processed it"
