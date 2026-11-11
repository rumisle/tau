#!/usr/bin/env bash
# The web app with hot reload, against a dev tau server (docs/web.md "Workflows"): the server with the dev model, which
# restarts when its code changes, and Vite's dev server, which proxies the socket, /auth and /files to it, so the app
# is same-origin as in production. Ctrl-C stops both.
# Usage: scripts/web/dev.sh [--port 7990] [--web-port 1234] [--db /tmp/tau-web-dev.db | --memory] [--model dev/echo]
#   [other server options...]
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
port=7990 web_port=1234 db=/tmp/tau-web-dev.db model=dev/echo storage=() rest=()
while [ $# -gt 0 ]; do
	case "$1" in
		--port) port="$2"; shift 2 ;;
		--web-port) web_port="$2"; shift 2 ;;
		--db) db="$2"; shift 2 ;;
		--memory) storage=(--memory); shift ;;
		--model) model="$2"; shift 2 ;;
		*) rest+=("$1"); shift ;;
	esac
done
[ ${#storage[@]} -gt 0 ] || storage=(--db "$db")
"$root/scripts/web/install.sh"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT INT TERM
(cd "$root/server" && exec node --no-warnings --watch src/main.ts "${storage[@]}" --port "$port" --host 127.0.0.1 \
	--model "$model" --no-web "${rest[@]}") &
pids+=($!)
(cd "$root/web" && TAU_DEV_SERVER="http://127.0.0.1:$port" APP_ENV=development exec node_modules/.bin/vite \
	--mode development --host 127.0.0.1 --port "$web_port") &
pids+=($!)
echo "tau web: http://127.0.0.1:$web_port (server on $port)"
wait -n
