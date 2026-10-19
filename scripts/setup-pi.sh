#!/usr/bin/env bash
# Check out pi at the commit in PI_REVISION into vendor/pi and build the packages tau links against.
# Usage: scripts/setup-pi.sh            build the pinned revision
#        scripts/setup-pi.sh --latest   move PI_REVISION to origin/main first
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
pi="$root/vendor/pi"

if [ ! -d "$pi/.git" ]; then
	git clone --filter=blob:none https://github.com/earendil-works/pi "$pi"
fi
git -C "$pi" fetch -q origin main
if [ "${1:-}" = "--latest" ]; then
	git -C "$pi" rev-parse origin/main > "$root/PI_REVISION"
fi
revision="$(cat "$root/PI_REVISION")"
git -C "$pi" -c advice.detachedHead=false checkout -q "$revision"
echo "pi at $(git -C "$pi" log -1 --format='%h %cd %s' --date=short)"

cd "$pi"
npm ci --ignore-scripts --no-audit --no-fund --loglevel=error
npm run --silent hydrate:model-data > /dev/null
# Durable and what it depends on, in dependency order.
for package in telemetry chord codemode; do
	(cd "packages/$package" && npm run --silent build)
done
(cd packages/ai && npm run --silent build:offline)
(cd packages/durable && npm run --silent build)

cd "$root/server"
npm install --ignore-scripts --no-audit --no-fund --loglevel=error
echo "done"
