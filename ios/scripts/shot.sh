#!/usr/bin/env bash
# Relaunch the installed app with launch arguments and screenshot the simulator.
# Usage: ios/scripts/shot.sh <out.png> [wait seconds] [-- app arguments...]
set -euo pipefail
out="$1"; wait="${2:-3}"; shift 2 || shift $#
[ "${1:-}" = "--" ] && shift
device="${TAU_SIMULATOR:-iPhone 17 Pro}"
xcrun simctl launch --terminate-running-process "$device" com.rumisle.tau "$@" > /dev/null
sleep "$wait"
xcrun simctl io "$device" screenshot "$out" > /dev/null 2>&1
echo "$out"
