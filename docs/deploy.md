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
startup files reach the server and its agents. The service has `OOMPolicy=continue`: when the kernel kills a
command an agent ran for memory, the server goes on (systemd's default, `OOMPolicy=stop`, stops the whole unit, every
run with it; docs/command-isolation.md). A service set up before has the line added by running `tau setup` again, or by
hand: `OOMPolicy=continue` in `[Service]`, then `systemctl --user daemon-reload` (it applies at the next start).
Setup also writes `~/.config/systemd/user/tau-cmd.slice`, the memory pool of the agents' commands when the server runs
each in its own scope (`--command-scopes` in the flags, off by default; docs/command-isolation.md): `MemoryMax=` the
machine's memory less a reserve (a tenth, at least 2 GiB), and `MemorySwapMax=0` where swap is zram. It is written once
and then yours to edit; setup keeps it, and warns when the user has no linger or the user manager has no memory
controller. `tau status` shows the slice and whether the flags turn scopes on.

`tau setup` takes options (and install.sh passes its own to it: `curl ... | sh -s -- --data /var/tmp/$USER/tau`); run
again, it changes only what it is given, and keeps the token, the other flags, their lines and comments:

- `--data DIR`: the data directory, absolute, in the flags (made, mode 700). When the data directory changes and only
  the old one has a database, setup stops the service (the server closes the database, SQLite folds the WAL in), checks
  nothing still has `tau.db` open, moves every `tau.*` there (the database, its `-wal`/`-shm`, the search index,
  `tau.files`, `tau.boot`), then writes the flags and starts it. Both with a database: it refuses. A `--db` in the flags
  it leaves to the user.
- The data must be on a local filesystem: SQLite's WAL needs every user of the database on one host
  (https://sqlite.org/wal.html). The server refuses to start on NFS, SMB/CIFS, Ceph, Lustre, AFS, 9p, GPFS, GlusterFS
  and the like (statfs's magic; a FUSE mount by its subtype; Linux only) with that reason, and setup asks it first
  (`tau-server.js --check-data`): with the data on one, the default directory on an NFS home included, setup changes
  nothing, starts nothing, and prints the command to rerun with `--data /var/tmp/$USER/tau` (when that is local).
- `--command-memory SIZE` (`32G`, `24000M`, `80%`, `infinity`): `MemoryMax=` in tau-cmd.slice, the rest of the file as it
  is, a comment above it saying setup set it.
- `--command-scopes`, `--no-command-scopes`: the flag in the flags.

Each run rewrites the service unit, reloads systemd and restarts the server. `tau upgrade` and `tau rollback` do not
run setup, so they change none of this. For a throwaway setup beside a real one: `TAU_LIB`, `TAU_CONFIG`, `TAU_BIN`,
`TAU_UNIT`, `TAU_UNITS` (a units directory such as `$XDG_RUNTIME_DIR/systemd/user`, enabled until reboot only) and
`TAU_COMMAND_SLICE` (written into the flags with `--command-scopes`), and flags with a `--data` and `--port` of its own.
Model logins are the pi CLI's (`~/.pi/agent/auth.json`) or the
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

**Rolling back across a pi bump.** A rollback only changes code, so it works as long as the older version reads what
the newer one stored: durable's SQLite schema, its document versions (`pi.live`, `pi.agent`, ...) and its task
versions (`pi.generation`, `pi.tool`, ...), and tau's own documents. A bump that moves any of them forward makes the
rollback one-way (the older durable leaves a newer task blocked, `task_too_old`, and cannot migrate a newer document).
Before releasing a bump, run the new server on a `.backup` copy of a real database, write to it (a chat, a run with a
tool call), then the old server on the same copy, and open every chat (`server/bench/runs.ts check`, `write`). From
4b535d57 to 35dfa757 nothing moved: the old server opened all 212 chats of a copy of a real server's after the new one had
written to it, and ran new chats.

Collection: after a switch that stays up, every version but `current` and `previous` is removed, and with it any
download a failure left. Two versions are kept, one to run and one to roll back to; `tau gc` does the same by hand.
