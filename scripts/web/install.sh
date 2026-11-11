#!/usr/bin/env bash
# Installs web/'s packages when its lockfile is newer than its node_modules (or there are none).
set -euo pipefail
web="$(cd "$(dirname "$0")/../../web" && pwd)"
if [ ! -d "$web/node_modules" ] || [ "$web/package-lock.json" -nt "$web/node_modules/.package-lock.json" ]; then
	(cd "$web" && npm ci --no-audit --no-fund --loglevel=error)
fi
