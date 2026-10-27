# Deploying the server

A release is the server as one bundle with pi in it (`scripts/build-release.sh`): `tau-server.js`, durable's image
worker beside it, the two WebAssembly packages it loads (QuickJS for code mode, Photon for images), and `bin/tau`. About
2.3 MB packed; a machine needs Node 22.18 or later, not vendor/pi. `scripts/release.sh` publishes one on GitHub as
`server-<version>` (the commit's date and short hash), with `install.sh` beside it.

## Install (Linux)

```bash
curl -fsSL https://github.com/rumisle/tau/releases/latest/download/install.sh | sh
```

It checks Node, downloads the latest release, checks that it starts, and runs `tau setup`: a token in
`~/.config/tau/token`, the server's options in `~/.config/tau/flags`, and the systemd user service `tau-server`
(started, and from boot with `loginctl enable-linger`). It prints the address (the tailnet name when Tailscale runs) and
the token for the app. The service runs `tau serve` through a login, interactive shell, so API keys set in the shell's
startup files reach the server and its agents. Model logins are the pi CLI's (`~/.pi/agent/auth.json`) or the
providers' API keys. The repository is private for now: give `TAU_GITHUB_TOKEN` (or `GITHUB_TOKEN`) to download.

## Upgrade, roll back

```
~/.local/lib/tau/
  versions/2026.10.27-6a23d4c/    a release, as it was unpacked
  versions/2026.10.28-0b1c2d3/
  current  -> versions/2026.10.28-0b1c2d3
  previous -> versions/2026.10.27-6a23d4c
~/.local/bin/tau -> ~/.local/lib/tau/current/bin/tau
```

`tau upgrade` downloads the latest release (or `tau upgrade <version>` that one) into `versions/`, checks it (it says
its version, and starts and listens with throwaway storage), then switches: `current` and `previous` are each replaced
in one step (a new link renamed over the old), and the service restarts. If it is not up and steady 10 seconds later
(active, no restarts since), the links go back and the old version restarts. `tau rollback` switches to `previous`.
The data and settings are elsewhere, so a switch only changes code. `tau` itself is in the release, so it upgrades
with it.

An agent of the server may run `tau upgrade` in a chat: the restart would stop the command halfway, so when `tau` runs
inside the service it hands the switch to a transient unit (`systemd-run`, `tau-switch-*`), which outlives the restart;
the chat resumes on the new version.

Collection: after a switch that stays up, every version but `current` and `previous` is removed, and with it any
download a failure left. Two versions are kept, one to run and one to roll back to; `tau gc` does the same by hand.
