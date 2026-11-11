#!/usr/bin/env bash
# The history walk's checklist, web/PARITY.md (docs/web.md "Scope"): appends tau's commits not yet listed, oldest first,
# as `todo`, and prints how many are in each state. A commit is listed when it touches the app, the server, the shared
# client or the docs; one that touches web/ brought its web side itself and is left out.
# Usage: scripts/web/parity.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
list="$root/web/PARITY.md"
if [ ! -f "$list" ]; then
	cat > "$list" <<'HEAD'
# Parity with tau's history

The web client catches up with tau by its commits, oldest first (docs/web.md "Scope"). A line per commit: its hash, its
state, its subject. States: `todo`; `done <web commit>`; `skip: <why>` (relevant, not done now); `deferred: <why>`
(put off by the user); `n/a: <why>` (nothing for the web to do). `scripts/web/parity.sh` appends new commits as `todo`.

HEAD
fi
known="$(grep -oE '^- `[0-9a-f]{7,}`' "$list" | grep -oE '[0-9a-f]{7,}' || true)"
added=0
while IFS=$'\t' read -r hash subject; do
	grep -qx "$hash" <<<"$known" && continue
	git -C "$root" diff-tree --no-commit-id --name-only -r "$hash" | grep -q '^web/' && continue
	[ ${#subject} -gt 110 ] && subject="${subject:0:109}…"
	printf -- '- `%s` todo — %s\n' "$hash" "$subject" >> "$list"
	added=$((added + 1))
done < <(git -C "$root" log --reverse --no-merges --format='%h%x09%s' -- ios/Tau server/src client docs)
echo "web/PARITY.md: $added added; $(grep -c '` todo' "$list" || true) todo, $(grep -c '` done' "$list" || true) done, $(grep -c '` skip' "$list" || true) skipped, $(grep -c '` deferred' "$list" || true) deferred, $(grep -c '` n/a' "$list" || true) n/a"
