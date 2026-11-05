#!/usr/bin/env bash
# Reproduces what a command that eats its memory does to a tau server today (docs/command-isolation.md, step 1): a dev
# server in a transient user unit with a small memory limit, as tau-server.service runs, and a chat whose command
# allocates past it. Prints what the driver (the model's side) saw, then the unit's state and its journal.
#
# Usage: scripts/oom-repro.sh [-s] [-p Property=Value ...]   extra unit properties, e.g. -p OOMPolicy=continue
#   -s             commands in scopes (step 5): the server with --command-scopes --command-slice tau-oomtest-cmd.slice,
#                  that slice given MemoryMax=2G MemorySwapMax=0 at runtime (no real tau-cmd.slice is touched), and a
#                  neighbor chat's background process first, to show the hog's scope dies alone
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
slice=tau-oomtest-cmd.slice
scopes=
if [ "${1:-}" = -s ]; then scopes=1; shift; fi
port="${TAU_OOM_PORT:-7993}"
hog="${TAU_OOM_HOG:-python3 -c 'a = bytearray(3 << 30); print(len(a))'}"
work="$(mktemp -d /tmp/tau-oomtest.XXXXXX)"
mkdir -p "$work/agent" "$work/data"
# This repro's own scopes: tau-oomtest-cmd-*.
own_scopes() { systemctl --user list-units --all --plain --no-legend "${slice%.slice}-*" | awk '{ print $1 }'; }
cleanup() {
	systemctl --user stop "$unit" 2>/dev/null
	systemctl --user reset-failed "$unit" 2>/dev/null
	if [ -n "$scopes" ]; then
		for scope in $(own_scopes); do
			systemctl --user stop "$scope" 2>/dev/null
			systemctl --user reset-failed "$scope" 2>/dev/null
		done
		systemctl --user stop tau-oomtest.slice 2>/dev/null
		systemctl --user revert "$slice" >/dev/null 2>&1
	fi
	rm -rf "$work"
}
trap cleanup EXIT
systemctl --user stop "$unit" 2>/dev/null
systemctl --user reset-failed "$unit" 2>/dev/null

since="$(date '+%Y-%m-%d %H:%M:%S')"
echo "== unit properties: MemoryMax=2G MemorySwapMax=0 Restart=always RestartSec=2 $*"
flags=()
if [ -n "$scopes" ]; then
	systemctl --user set-property --runtime "$slice" MemoryMax=2G MemorySwapMax=0 || exit 1
	flags=(--command-scopes --command-slice "$slice")
	echo "== commands in scopes: $slice, MemoryMax=2G MemorySwapMax=0"
fi
systemd-run --user --quiet --unit="$unit" --working-directory="$root/server" \
	-p MemoryMax=2G -p MemorySwapMax=0 -p Restart=always -p RestartSec=2 "$@" \
	-E PI_CODING_AGENT_DIR="$work/agent" -E PATH=/usr/local/bin:/usr/bin:/bin \
	-- "$(command -v node)" --no-warnings src/main.ts --data "$work/data" --port "$port" --host 127.0.0.1 --cwd "$work" ${flags[@]+"${flags[@]}"} || exit 1

echo "== the model's side"
neighbor=()
[ -n "$scopes" ] && neighbor=('sleep 600 >/dev/null 2>&1 & echo "pid $!"; cat /proc/self/cgroup')
(cd "$root/server" && node --no-warnings ../scripts/oom-repro.ts "ws://127.0.0.1:$port" "$hog" ${neighbor[@]+"${neighbor[@]}"})
sleep 3

echo "== the unit"
systemctl --user show "$unit" -p ActiveState -p SubState -p Result -p NRestarts -p OOMPolicy -p MemoryPeak | sed 's/^/    /'
echo "== its journal"
journalctl --user -u "$unit" --since "$since" -o short-monotonic --no-pager | grep -vE "^\s*$" | grep -iE "oom|kill|exited|failed|start|stopp|restart|consumed|listening" | sed -E 's/^\[ *[0-9.]+\] [^ ]+ //; s/^/    /' | head -30
if [ -n "$scopes" ]; then
	echo "== the server's own cgroup"
	cgroup="$(systemctl --user show "$unit" -p ControlGroup --value)"
	echo "    oom_kill $(awk '/^oom_kill / { print $2 }' "/sys/fs/cgroup$cgroup/memory.events")"
	echo "== the commands' scopes left"
	for scope in $(own_scopes); do
		[ "${scope##*.}" = scope ] && echo "    $scope $(systemctl --user show "$scope" -p ActiveState -p Result | tr '\n' ' ')"
	done
	echo "== their journal"
	journalctl --user --since "$since" -o short-monotonic --no-pager | grep -F "${slice%.slice}-" | grep -iE "oom|failed|consumed" | sed -E 's/^\[ *[0-9.]+\] [^ ]+ //; s/^/    /' | head -10
fi
