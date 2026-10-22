#!/usr/bin/env bash
# Run SendingUITests (docs/sending.md) against the dev server, stopping, starting and wiping it when a test asks:
# the test drops /tmp/tau-ui/server-<action>, this script acts and answers with /tmp/tau-ui/server-<action>ed.
# Usage: ios/scripts/sending-tests.sh [testName ...]   (default: all of SendingUITests)
set -uo pipefail
cd "$(dirname "$0")/.."
DEV=scripts/devserver.sh
$DEV start
# testPromptCache's server: the dev model with a 15 s prompt cache, priced so that warming it pays; in memory.
CACHE=
if ! nc -z 127.0.0.1 7982 2>/dev/null; then
  (cd ../server && exec env -u OPENAI_API_KEY node --no-warnings src/main.ts --memory --port 7982 --host 127.0.0.1 --dev-tps 40 --dev-cache-ttl 15 --cwd /tmp) >/tmp/tau-cache-server.log 2>&1 &
  CACHE=$!
fi
( while true; do
    for action in stop start wipe; do
      if [ -f /tmp/tau-ui/server-$action ]; then
        rm -f /tmp/tau-ui/server-$action
        case $action in
          stop) $DEV stop ;;
          start) $DEV start ;;
          wipe) $DEV stop; $DEV wipe; $DEV start ;;
        esac
        touch /tmp/tau-ui/server-${action}ed
      fi
    done
    sleep 0.2
  done ) &
WATCH=$!
tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
  tests=($(grep -o 'func test[A-Za-z]*' TauUITests/SendingUITests.swift | sed 's/func //'))
fi
scripts/uitest.sh "${tests[@]/#/SendingUITests/}"
kill $WATCH
[ -n "$CACHE" ] && kill $CACHE
$DEV start
