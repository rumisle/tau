#!/usr/bin/env bash
# Record local changes to vendored Telegram files as a patch that vendor_telegram.py reapplies.
# Usage: ios/scripts/make_patch.sh <patch name> <file relative to ios/ThirdParty/Telegram>...
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
name="$1"; shift
out="$root/ios/ThirdParty/telegram-patches/$name.patch"
: > "$out"
for file in "$@"; do
	diff -u --label "a/$file" --label "b/$file" "$root/vendor/Telegram-iOS/$file" "$root/ios/ThirdParty/Telegram/$file" >> "$out" || true
done
echo "wrote $out ($(grep -c '^[-+][^-+]' "$out") changed lines)"
