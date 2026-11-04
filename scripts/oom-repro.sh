#!/usr/bin/env bash
# Reproduces what a command that eats its memory does to a tau server today (docs/command-isolation.md, step 1): a dev
# server in a transient user unit with a small memory limit, as tau-server.service runs, and a chat whose command
# allocates past it. Prints what the driver (the model's side) saw, then the unit's state and its journal.
#
# Usage: scripts/oom-repro.sh [-p Property=Value ...]   extra unit properties, e.g. -p OOMPolicy=continue
#   TAU_OOM_PORT   the server's port (7993)
#   TAU_OOM_HOG    the command (python3 allocating and touching 3 GB)
#
# The unit is tau-oomtest: MemoryMax=2G, MemorySwapMax=0 (zram's compressed pages are charged to no cgroup, so swap is
# bounded too), Restart=always, RestartSec=2 as tau-server.service has them. It is stopped and its failed state reset
# afterwards, that unit's only. The server keeps its data in a temporary directory, removed at the end; it has no
# credentials, and binds to loopback.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
unit=tau-oomtest
port="${TAU_OOM_PORT:-7993}"
hog="${TAU_OOM_HOG:-python3 -c 'a = bytearray(3 << 30); print(len(a))'}"
work="$(mktemp -d /tmp/tau-oomtest.XXXXXX)"
mkdir -p "$work/agent" "$work/data"
cleanup() {
	systemctl --user stop "$unit" 2>/dev/null
	systemctl --user reset-failed "$unit" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT
systemctl --user stop "$unit" 2>/dev/null
systemctl --user reset-failed "$unit" 2>/dev/null

since="$(date '+%Y-%m-%d %H:%M:%S')"
echo "== unit properties: MemoryMax=2G MemorySwapMax=0 Restart=always RestartSec=2 $*"
systemd-run --user --quiet --unit="$unit" --working-directory="$root/server" \
	-p MemoryMax=2G -p MemorySwapMax=0 -p Restart=always -p RestartSec=2 "$@" \
	-E PI_CODING_AGENT_DIR="$work/agent" -E PATH=/usr/local/bin:/usr/bin:/bin \
	-- "$(command -v node)" --no-warnings src/main.ts --data "$work/data" --port "$port" --host 127.0.0.1 --cwd "$work" || exit 1

echo "== the model's side"
(cd "$root/server" && node --no-warnings ../scripts/oom-repro.ts "ws://127.0.0.1:$port" "$hog")
sleep 3

echo "== the unit"
systemctl --user show "$unit" -p ActiveState -p SubState -p Result -p NRestarts -p OOMPolicy -p MemoryPeak | sed 's/^/    /'
echo "== its journal"
journalctl --user -u "$unit" --since "$since" -o short-monotonic --no-pager | grep -vE "^\s*$" | grep -iE "oom|kill|exited|failed|start|stopp|restart|consumed|listening" | sed -E 's/^\[ *[0-9.]+\] [^ ]+ //; s/^/    /' | head -30
