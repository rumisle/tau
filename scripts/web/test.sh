#!/usr/bin/env bash
# The web client's checks and tests (docs/web.md "Tests, fast"), fastest first; stops at the first that fails.
#   static   no middle dot in tau's copy; TypeScript 7 (the server's) over web/ and client/; ESLint and Stylelint on
#            tau's files and the Web A files tau edited; every edit to Web A marked `tau:` (scripts/web/upstream.ts diff
#            --check, when vendor/telegram-tt is)
#   unit     client/ (node:test), web/src/tau (Vitest)
#   e2e      the built app against dev servers (web/e2e, Playwright); built first when its sources are newer
#   smoke    e2e's tests tagged @smoke only (open, read, send, steer and stop, files, a new chat), under 15 s
#   --dev    e2e and smoke against Vite's dev server instead of a build, so an edit is in the next run at once: it
#            starts one on 1234 without hot reload when none answers there, and leaves it running for the next run
# Usage: scripts/web/test.sh [static|unit|e2e|smoke]... [--dev] [-- playwright options, e.g. a spec file]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
web="$root/web"
steps=() pass=() dev=
while [ $# -gt 0 ]; do
	case "$1" in --) shift; pass=("$@"); break ;; --dev) dev=1; shift ;; *) steps+=("$1"); shift ;; esac
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
	# tau's copy is terse and never joins parts with a middle dot (as iOS's: "Connected, ping 42 ms", "provider/id")
	if grep -rn --include='*.ts' --include='*.tsx' --exclude='*.test.ts' '·' "$web/src/tau"; then
		echo "a middle dot in tau's copy (above): say it as iOS does" >&2
		exit 1
	fi
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

# Vite's dev server for e2e --dev, on 1234 (its own, without hot reload: the tests' tau servers stand in front of it)
dev_server() {
	local url=http://127.0.0.1:1234
	if ! curl -sf -o /dev/null "$url/"; then
		# Its own session, holding none of this script's descriptors: a pipe reading this script's output ends with it
		(cd "$web" && TAU_DEV_NO_HMR=1 APP_ENV=development setsid -f node_modules/.bin/vite --mode development \
			--host 127.0.0.1 --port 1234) < /dev/null > /tmp/tau-web-e2e-vite.log 2>&1
		for _ in $(seq 100); do curl -sf -o /dev/null "$url/" && break; sleep 0.2; done
		# Its first page compiles Web A's modules on demand: once here, not in each test's first page
		curl -sf -o /dev/null "$url/src/index.tsx" || true
	fi
	export TAU_E2E_WEB_DEV="$url"
}

e2e() {
	if [ -n "$dev" ]; then
		dev_server
		(cd "$web/e2e" && node_modules/.bin/playwright test "${pass[@]}")
		return
	fi
	if [ ! -f "$web/dist/index.html" ] || [ -n "$(find "$web/src" "$web/index.html" "$web/vite.config.ts" "$root/client/src" -newer "$web/dist/index.html" -print -quit)" ]; then
		timed build "$root/scripts/web/build.sh" > /dev/null
	fi
	(cd "$web/e2e" && node_modules/.bin/playwright test "${pass[@]}")
}

smoke() {
	pass=(--grep @smoke "${pass[@]}")
	e2e
}

for step in "${steps[@]}"; do timed "$step" "$step"; done
