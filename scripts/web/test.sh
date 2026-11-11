#!/usr/bin/env bash
# The web client's checks and tests (docs/web.md "Tests, fast"), fastest first; stops at the first that fails.
#   static   TypeScript 7 (the server's) over web/ and client/; ESLint and Stylelint on tau's files and the Web A files tau
#            edited; every edit to Web A marked `tau:` (scripts/web/upstream.ts diff --check, when vendor/telegram-tt is)
#   unit     client/ (node:test), web/src/tau (Vitest)
#   e2e      the built app against dev servers (web/e2e, Playwright); built first when its sources are newer
# Usage: scripts/web/test.sh [static|unit|e2e]... [-- playwright options]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
web="$root/web"
steps=() pass=()
while [ $# -gt 0 ]; do
	case "$1" in --) shift; pass=("$@"); break ;; *) steps+=("$1"); shift ;; esac
done
[ ${#steps[@]} -gt 0 ] || steps=(static unit e2e)
tsc="$root/server/node_modules/.bin/tsc"
"$root/scripts/web/install.sh"
[ -d "$web/e2e/node_modules" ] || (cd "$web/e2e" && npm ci --no-audit --no-fund --loglevel=error)

timed() {
	local name="$1"; shift
	local start=$SECONDS
	"$@"
	echo "== $name: $((SECONDS - start)) s"
}

edited() {
	node --no-warnings "$root/scripts/web/upstream.ts" diff --stat | tail -n +2 | sed 's/^ *//' | grep -E "$1" | sed "s#^#$web/#" || true
}

static() {
	"$tsc" -p "$web" --noEmit
	(cd "$root/client" && "$tsc" --noEmit)
	if [ -d "$root/vendor/telegram-tt/.git" ]; then
		node --no-warnings "$root/scripts/web/upstream.ts" diff --check
		mapfile -t ts < <(edited '\.(ts|tsx)$')
		mapfile -t scss < <(edited '\.scss$')
	else
		echo "no vendor/telegram-tt: Web A's edits not checked (node scripts/web/upstream.ts diff --check fetches it)"
		ts=() scss=()
	fi
	(cd "$web" && node_modules/.bin/eslint --cache --cache-location .cache/.eslintcache src/tau "${ts[@]}")
	"$tsc" -p "$web/e2e"
	(cd "$web" && node_modules/.bin/stylelint --cache --cache-location .cache/.stylelintcache "src/tau/**/*.scss" "${scss[@]}")
}

unit() {
	(cd "$root/client" && node --no-warnings --test test/*.test.ts > /tmp/tau-client-test.log) || { cat /tmp/tau-client-test.log; exit 1; }
	(cd "$web" && node_modules/.bin/vitest run --config tau.vitest.config.ts --silent=passed-only)
}

e2e() {
	if [ ! -f "$web/dist/index.html" ] || [ -n "$(find "$web/src" "$web/index.html" "$web/vite.config.ts" "$root/client/src" -newer "$web/dist/index.html" -print -quit)" ]; then
		timed build "$root/scripts/web/build.sh" > /dev/null
	fi
	(cd "$web/e2e" && node_modules/.bin/playwright test "${pass[@]}")
}

for step in "${steps[@]}"; do timed "$step" "$step"; done
