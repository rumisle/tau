#!/usr/bin/env bash
# Run SendingUITests (docs/sending.md) against the dev server, stopping, starting and wiping it when a test asks:
# the test drops /tmp/tau-ui/server-<action>, this script acts and answers with /tmp/tau-ui/server-<action>ed.
# Usage: ios/scripts/sending-tests.sh [testName ...]   (default: all of SendingUITests)
set -uo pipefail
cd "$(dirname "$0")/.."
DEV=scripts/devserver.sh
$DEV start
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
$DEV start
