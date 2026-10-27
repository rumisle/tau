#!/usr/bin/env bash
# Builds a release of the server and publishes it on GitHub as server-<version>, with the installer beside it
# (docs/deploy.md). Usage: scripts/release.sh [version]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit first: a release is built from a commit" >&2; exit 1; }
tarball="$(scripts/build-release.sh "$@" | tail -n 1 | cut -d' ' -f1)"
version="$(basename "$tarball" .tar.gz)"; version="${version#tau-server-}"
gh release create "server-$version" "$tarball" scripts/install.sh --target "$(git rev-parse HEAD)" \
	--title "tau server $version" --notes "Install on Linux: \`curl -fsSL https://github.com/rumisle/tau/releases/latest/download/install.sh | sh\`. Upgrade: \`tau upgrade\`."
echo "released $version"
