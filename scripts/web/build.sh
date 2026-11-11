#!/usr/bin/env bash
# Builds the web app (docs/web.md) into web/dist, which the server serves from a checkout and a release carries:
# Vite's production build, without source maps.
# Usage: scripts/web/build.sh [out dir]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(realpath -m "${1:-$root/web/dist}")"
"$root/scripts/web/install.sh"
cd "$root/web"
APP_ENV=production node_modules/.bin/vite build --mode production --outDir "$out" --emptyOutDir --logLevel error
find "$out" -name '*.map' -delete
echo "$out ($(du -sh "$out" | cut -f1))"
