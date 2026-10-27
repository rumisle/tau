#!/bin/sh
# Installs tau's server on Linux (docs/deploy.md): the latest release in ~/.local/lib/tau, `tau` in ~/.local/bin, and
# the systemd user service, started.
#   curl -fsSL https://github.com/rumisle/tau/releases/latest/download/install.sh | sh
# Needs Node 22.18 or later, curl, tar, and systemd. TAU_REPO, TAU_GITHUB_TOKEN as for tau (scripts/tau).
set -eu
repo="${TAU_REPO:-rumisle/tau}"
token="${TAU_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
die() { echo "tau install: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "this installer is for Linux for now"
command -v systemctl >/dev/null || die "no systemctl: the installer needs systemd"
command -v curl >/dev/null || die "no curl"
command -v tar >/dev/null || die "no tar"
command -v node >/dev/null || die "no node: install Node 22.18 or later (https://nodejs.org, or your package manager), then run this again"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=18)?0:1)' \
	|| die "node $(node -p process.versions.node) is too old: tau needs 22.18 or later"

api() { curl -fsSL -H "Accept: ${2:-application/vnd.github+json}" ${token:+-H "Authorization: Bearer $token"} "https://api.github.com/repos/$repo/$1"; }
tag="$(api releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$tag" ] || die "no release found in $repo"
version="${tag#server-}"

# The release's own tau does the rest: the download, the check that it starts, the links; then the service.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [ -n "$token" ]; then
	id="$(api "releases/tags/$tag" | tr ',{' '\n\n' | grep -B30 "\"name\": *\"tau-server-$version.tar.gz\"" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | tail -n 1)"
	api "releases/assets/$id" application/octet-stream | tar -xz -C "$work"
else
	curl -fsSL "https://github.com/$repo/releases/download/$tag/tau-server-$version.tar.gz" | tar -xz -C "$work"
fi
"$work/tau-server-$version/bin/tau" upgrade "$version"
"$HOME/.local/bin/tau" setup
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to your PATH to run tau." ;; esac
