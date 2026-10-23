#!/usr/bin/env bash
# Dev server for the sending UI tests: dev/echo model, a database that survives restarts. Port 7979 and /tmp/tau-dev.db,
# or TAU_DEV_PORT and TAU_DEV_DB: ios/scripts/uitests.sh runs one per simulator.
PORT=${TAU_DEV_PORT:-7979}
DB=${TAU_DEV_DB:-/tmp/tau-dev.db}
STATE=/tmp/tau-dev-session$([ "$PORT" = 7979 ] || echo "-$PORT")
S=$(cat "$STATE" 2>/dev/null)
# Never an empty target: tmux takes it for the pane it runs in.
[ -n "$S" ] && tmux has-session -t "$S" 2>/dev/null || S=
case "$1" in
  stop)
    # Until the port is free, and the process gone: a start right after must not find the old server still shutting
    # down,
    [ -n "$S" ] && tmux send-keys -t "$S" C-c 2>/dev/null
    # and the process gone, which a running tool (`$ sleep 20`) can hold for its whole length: a crash, then.
    for i in $(seq 1 12); do pgrep -f "src/main.ts --db $DB " >/dev/null || break; sleep 0.25; done
    pkill -9 -f "src/main.ts --db $DB " 2>/dev/null
    for i in $(seq 1 20); do nc -z 127.0.0.1 "$PORT" 2>/dev/null || break; sleep 0.25; done ;;
  start)
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && exit 0
    [ -n "$S" ] || { S=pi-tauDev-$(openssl rand -hex 3); echo "$S" > "$STATE"; tmux new-session -d -s "$S" -c "$(cd "$(dirname "$0")/../../server" && pwd)"; }
    tmux send-keys -t "$S" "env -u OPENAI_API_KEY node --no-warnings src/main.ts --db $DB --port $PORT --host 127.0.0.1 --dev-tps ${TPS:-20} --cwd /tmp" Enter
    for i in $(seq 1 40); do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.25; done ;;
  wipe)
    rm -f "$DB"* "${DB%.db}.search.db"*
    # Its files are read-only, in read-only directories (server/src/files.ts).
    [ -d "${DB%.db}.files" ] && chmod -R u+w "${DB%.db}.files" && rm -rf "${DB%.db}.files"
    ;;
esac
