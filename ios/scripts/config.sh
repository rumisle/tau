# Sourced by the scripts: the bundle ID and team from Config/Local.xcconfig (else Config/Tau.xcconfig's defaults),
# as Xcode reads them. TAU_TEAM in the environment overrides the team.
tau_setting() {
	local value
	for file in Config/Local.xcconfig Config/Tau.xcconfig; do
		[ -f "$file" ] || continue
		value=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$file" | tail -n 1)
		[ -n "$value" ] && { echo "$value"; return; }
	done
}
bundle=$(tau_setting TAU_BUNDLE_ID)
team="${TAU_TEAM:-$(tau_setting DEVELOPMENT_TEAM)}"
