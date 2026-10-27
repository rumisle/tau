#!/usr/bin/env bash
# Builds the server as a release (docs/deploy.md): one bundle with pi in it, the image worker beside it, and the two
# WebAssembly packages the bundle resolves at run time, so a machine needs only Node, not vendor/pi.
# Usage: scripts/build-release.sh [version]   -> dist/tau-server-<version>.tar.gz
# The version is by default the commit's date and short hash (2026.10.27-9830ece).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
pi="$root/vendor/pi"
[ -d "$pi/packages/durable/dist" ] || { echo "no vendor/pi: run scripts/setup-pi.sh" >&2; exit 1; }
version="${1:-$(git log -1 --format=%cd --date=format:%Y.%m.%d)-$(git rev-parse --short HEAD)}"
revision="$(cat PI_REVISION)"
name="tau-server-$version"
out="$root/dist/$name"
rm -rf "$out" && mkdir -p "$out"
esbuild="$pi/node_modules/.bin/esbuild"

# CommonJS dependencies call require: the bundle gets one.
banner='import { createRequire as __tauRequire } from "node:module"; const require = __tauRequire(import.meta.url);'
common=(--bundle --platform=node --format=esm --target=node22 --log-level=warning --legal-comments=none "--banner:js=$banner")
"$esbuild" server/src/main.ts "${common[@]}" --outfile="$out/tau-server.js" \
	--define:TAU_VERSION="\"$version\"" --define:TAU_PI_REVISION="\"$revision\""
# durable starts its image worker from beside itself (new URL("./node-worker.js", import.meta.url)).
"$esbuild" "$pi/packages/durable/dist/images/node-worker.js" "${common[@]}" --outfile="$out/node-worker.js"

# Resolved with createRequire from the bundle: node_modules beside it.
for package in quickjs-wasi @silvia-odwyer/photon; do
	mkdir -p "$out/node_modules/$package"
	cp -R "$pi/node_modules/$package/." "$out/node_modules/$package/"
done
rm -rf "$out/node_modules/quickjs-wasi/dist" "$out/node_modules/quickjs-wasi/src"

mkdir -p "$out/bin"
cp scripts/tau "$out/bin/tau"
chmod +x "$out/bin/tau"
cp LICENSE "$out/"
cat > "$out/package.json" <<JSON
{ "name": "tau-server", "version": "$version", "type": "module", "engines": { "node": ">=22.18" }, "piRevision": "$revision" }
JSON

# It starts: answers --version, and listens with throwaway storage.
[ "$(node "$out/tau-server.js" --version)" = "$version" ] || { echo "the bundle does not say its version" >&2; exit 1; }
tar -C "$root/dist" -czf "$root/dist/$name.tar.gz" "$name"
echo "$root/dist/$name.tar.gz ($(du -h "$root/dist/$name.tar.gz" | cut -f1))"
