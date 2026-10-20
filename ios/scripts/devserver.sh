#!/usr/bin/env bash
# Dev server for the sending UI tests: dev/echo model, port 7979, a database that survives restarts.
S=$(cat /tmp/tau-dev-session 2>/dev/null)
case "$1" in
  stop) tmux send-keys -t "$S" C-c 2>/dev/null; sleep 1 ;;
  start)
    nc -z 127.0.0.1 7979 2>/dev/null && exit 0
    tmux has-session -t "$S" 2>/dev/null || { S=pi-tauDev-$(openssl rand -hex 3); echo $S > /tmp/tau-dev-session; tmux new-session -d -s "$S" -c "$(cd "$(dirname "$0")/../../server" && pwd)"; }
    tmux send-keys -t "$S" "env -u OPENAI_API_KEY node --no-warnings src/main.ts --db /tmp/tau-dev.db --port 7979 --host 127.0.0.1 --dev-tps ${TPS:-20} --cwd /tmp" Enter
    for i in $(seq 1 40); do nc -z 127.0.0.1 7979 2>/dev/null && break; sleep 0.25; done ;;
  wipe) rm -f /tmp/tau-dev.db* ;;
esac
