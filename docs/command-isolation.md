# Command isolation (design notes, not built)

Where the discussion of the agents' commands, memory and the server got to, so it can be picked up without starting
over. Nothing here is implemented. The research behind it (sources, file and line references, measurements on chorus)
is kept outside the repository, in `~/research/isolation-research.md` on chorus.

## The problem

Every command an agent runs (the bash tool: durable's `src/tools/bash.ts`, `src/env/node.ts`) is a child of the tau
server, in the server's cgroup, with no limit. One command that eats the machine's memory:

- takes the server with it: the unit's `OOMPolicy=stop` (systemd's default) stops the whole service when the kernel
  kills any one process in it, and the server restarts with every run interrupted;
- can freeze the host before the kernel's OOM killer acts (reclaim thrashes; worse with a large disk swap);
- is run again: after the restart the model reads only "Tool bash was interrupted by a restart and may have partially
  run", or "exited with code 137" if only the command died, and the natural next step is to run it as it was.
  durable ends this after `settings.restartLimit` (5) crashes, so a machine can go down about five times.

**Evidence.** A comparable agent server on a large shared machine (a systemd user service, agents' jobs in its cgroup,
`OOMPolicy=stop`, `MemoryMax=1200G`) hit its limit, had 77 kernel OOM kills and restarted 49 times, 35 of them in one
half hour, each run peaking at 1.1T. On chorus the freezes are **not** shown to come from tau's commands: the journal
has no OOM kill, and the last one came while idle. The first step below is to find out.

## Principles

- **Mechanism in tau, policy in configuration.** tau starts each command in a systemd scope, stops it on abort, and
  reports what systemd says about it. How much memory commands may use, what is reserved for the host, swap: a slice
  unit file `tau setup` installs with defaults and the user edits. No sizes in tau's code.
- **systemd owns the cgroups.** As runc, crun and podman do with the systemd cgroup driver, and as Kubernetes advises
  on systemd hosts: one manager of the tree, tau asks it for units.
- **One code path.** Linux with a systemd user manager (cgroup v2, lingering, the memory controller delegated). No
  degraded levels or fallbacks that nothing exercises. macOS is out of scope for now.
- **Facts, not interpretation.** The model gets what happened, as Docker (`OOMKilled`) and Kubernetes
  (`reason: OOMKilled`) report it, not tau's guess at why the kernel chose that process.
- **No behavior change on the side.** A command's processes live as long as they do now. Whatever isolation adds
  must be invisible to the agent until something goes wrong.
- **durable continues after a restart**, a reboot included. The guard against crash loops is that runaway commands
  no longer bring the machine or the server down, and that the model learns what happened.

## Design

### The server's unit

- `OOMPolicy=continue`: a command killed for memory does not stop the server.
- The server cannot lower its own OOM score without privileges; the commands' scopes raise theirs
  (`OOMScoreAdjust=`, e.g. 500), so the kernel prefers them.

### Each command in a scope

The bash tool starts its command as

```
systemd-run --user --scope --quiet --unit=tau-cmd-<conversation>-<call> --slice=tau-cmd.slice \
  -p PartOf=tau-server.service -p OOMScoreAdjust=500 -- bash -c <command>
```

as an argument list, with no shell quoting. A scope inherits the caller's environment, working directory, standard
streams and process group, so the tool's pipes and its `kill(-pid)` keep working. Measured on chorus: about 3 ms per
command.

- **Lifetime, as now.** A command's background processes keep running after it returns (`npm run dev &` and a later
  `curl` work as today); the scope lasts while they do, and systemd collects it when they end.
- **Stop and timeout** stop the call's scope instead of killing its process group: the same call's processes, now
  including those that left the group (`setsid`, `nohup`, daemons). Other calls and conversations are untouched.
- **The server stopping** stops the scopes (`PartOf=`), as stopping the service kills its cgroup now. Commands do not
  outlive the server: after a restart durable has settled their calls as interrupted and nothing would read them.
  To verify on chorus: that a transient scope takes `PartOf=`.
- **Results.** When the command ends, tau reads the scope (`systemctl --user show -p Result -p MemoryPeak`); a failed
  scope stays until read, unless `--collect` is given, which tau does not. Then `reset-failed`.
- **At start** tau lists `tau-cmd-*` and settles what a crash left: reads and resets the failed, stops the running.

### What the model reads

Killed by the OOM killer:

```
Killed by the out-of-memory killer (exit 137).
Memory limit reached: 26 GB (tau-cmd.slice). This command's peak: 20 GB.
```

The limit named is the unit whose limit was reached (the command's own scope if it had one, else the slice). The
structured output carries the same: `oomKilled`, `memoryLimit`, `memoryLimitUnit`, `memoryPeak`.

Interrupted by a restart: the call records `/proc/sys/kernel/random/boot_id` when it starts; if it differs after the
restart,

```
The machine rebooted while this command ran (boot ID changed).
```

else that the tau server restarted while it ran.

### The slice (policy)

`tau-cmd.slice`, installed by `tau setup`, every command's scope in it:

- `MemoryMax=`: the pool all commands share, the machine's memory less a reserve for the host and the server. One
  command may use the whole pool; there is no per-command limit by default (a large build may need it all).
- Hosts with zram swap (chorus): zram's compressed memory is charged to no cgroup, so the pool's swap is bounded too
  (`MemorySwapMax=`).
- Hosts with no swap: `MemoryMax=` alone gives a prompt OOM kill inside the slice.
- Page cache counts toward `memory.current` and is reclaimed before an OOM kill; judge a slice by its working set.

In a shared pool the kernel kills the process with the highest badness (mostly the largest), which need not be the one
whose allocation crossed the limit. The message says which limit was reached and this command's peak, nothing more.

## bgjob first

`bgjob` (agent-config) runs background jobs on a private tmux server, a daemon that the first `bgjob start` launches
and that forks every later job. Today it escapes the calling command's process group with `setsid`, so Stop never
reaches the jobs (and a tau restart, which kills tau's cgroup, kills them all). In a scope it cannot escape: the tmux
server, and every job of every conversation after it, would sit in the scope of the call that happened to start it.
Stopping that call while it still runs (`bgjob start x -- …; bgjob wait x` in one call, the first time) would kill all
jobs, and every job's memory and OOM would be counted to that call.

So bgjob changes before tau's commands move into scopes: each job its own transient service, belonging to no call.

```
systemd-run --user --unit=bgjob-<id> --slice=agent-jobs.slice --collect \
  -p StandardOutput=append:<dir>/log -p StandardError=append:<dir>/log \
  -p ExecStopPost=<write $SERVICE_RESULT and $EXIT_STATUS to <dir>/result> -- bash <dir>/run
```

- `start` returns the ID; `wait -t` waits for `result`; `log` (and `peek`, the same without a terminal) tails the log;
  `kill` stops the service, every process in it; `ls` reads the job directories.
- systemd writes the result itself (`oom-kill`, `exit-code`, `signal`) whatever became of the caller; `--collect`
  removes the unit once it ends.
- A transient service does not inherit the caller's environment or directory: `start` writes them into `run`
  (`declare -px`, `cd`).
- No terminal: progress bars and prompts change. Keep a `--tty` mode on tmux for the rare job that needs one.
- Its directory moves off `/tmp` (on chorus a 16G tmpfs: logs there are memory).

## Reproduction

`scripts/oom-repro.sh [-p Property=Value ...]` (step 1) runs a dev tau server in a transient user unit as
tau-server.service runs (`MemoryMax=2G`, `MemorySwapMax=0`, `Restart=always`, `RestartSec=2`, and the properties
given), has a chat on the dev model run `python3 -c 'a = bytearray(3 << 30)'`, and prints what the model got back, the
unit's state and its journal; then stops the unit and resets that unit's failed state. On chorus, today
(`OOMPolicy=stop`, systemd's default):

```
[driver] connection dropped after 1.0 s (the server went away); reconnecting
[driver] server restarts seen by the driver: 1
[driver] tool result (isError true):
    [error] Tool bash was interrupted and may have partially run
== the unit
    NRestarts=1  OOMPolicy=stop
== its journal
    tau-oomtest.service: The kernel OOM killer killed some processes in this unit.
    node: stopping...
    tau-oomtest.service: Failed with result 'oom-kill'.
    tau-oomtest.service: Consumed 1.307s CPU time over 1.701s wall clock time, 2G memory peak.
    tau-oomtest.service: Scheduled restart job, restart counter is at 1.
```

The kernel killed only python; systemd then stopped the whole unit for it, the server with every run, and restarted
it. The model reads that its command was interrupted, nothing about memory, and would run it again.

## Order of work

Each step ships and reverts alone.

1. **Reproduce.** On chorus, a dev tau server inside a transient unit with a small `MemoryMax`, an agent running a
   memory hog: record what the server, the unit and the model see today. The same script checks every later step.
2. **`OOMPolicy=continue`** in the unit `tau setup` writes (and in the other servers' units).
3. **The model reads what happened**: exit by signal reported as such, the boot ID check. tau code only.
4. **bgjob on transient services**, beside the old one until it has been used for a while.
5. **Commands in scopes**, behind a flag, on chorus first; then the default, with `tau setup` installing the slice and
   checking the user manager (linger, delegated memory controller).

## Not part of this

- macOS.
- Killing a command's background processes when it returns. That would change what agents can do (dev servers,
  databases started with `&`); if wanted, a decision of its own.
- Default per-command memory limits.
- Commands surviving a server restart (reattaching to them is durable's matter).
- A token or spending budget, CPU and IO weights (the CPU controller is not always enabled for user slices),
  filesystem and network sandboxing.
- Host settings tau cannot make without root: swap (chorus's 64G swap is a file on btrfs behind a loop device, which
  btrfs no longer needs), systemd-oomd, kernel parameters. A `tau doctor` may point them out.
- Temporary files: a `TMPDIR` per conversation, cleaned with it, off tmpfs and NFS (a separate note).

## Notes on hosts

- **chorus**: Fedora, 30G RAM, zram 8G plus the 64G loop swap, `/tmp` a 16G tmpfs (5.4G used, mostly agents' leftovers),
  systemd-oomd present (pressure policy only), the user manager delegates `cpu io memory pids`.
- **A shared Ubuntu 24.04 machine** (systemd 255: `MemoryPeak` and `Result=oom-kill`, no `OOMKills` property): a
  Kubernetes node running storage daemons, so a runaway command endangers the cluster, not only the user; no swap,
  overcommit on, home on NFS (hard mounts). tau's database must be on local disk: SQLite's WAL needs shared memory and
  every user of the file on one host, which NFS does not give; `/var/tmp` is local and not cleaned there, `/tmp` is
  emptied at boot. Transient scopes and services work for the user without root; the CPU controller is not enabled
  below `app.slice`.
