# Command isolation (design notes, steps 1 to 3 built, step 5 behind a flag)

Where the discussion of the agents' commands, memory and the server got to, so it can be picked up without starting
over. Built: the reproduction (`scripts/oom-repro.sh`), `OOMPolicy=continue` in the unit `tau setup` writes, and what
the model reads of a command killed by a signal, an OOM kill in the server's cgroup, and a restart
(`server/src/commands.ts`); and, behind `--command-scopes` (off by default), each command in its own scope
(`server/src/scopes.ts`) with the slice `tau setup` writes. bgjob is not changed. See Order of work. The research behind it (sources, file and line references, measurements on chorus)
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
- The server cannot lower its own OOM score without privileges; the commands raise theirs to 500, so the kernel
  prefers them. Measured on chorus (systemd 259): a transient scope does not take `OOMScoreAdjust=` ("Unknown
  assignment"; it is an exec setting, and a scope execs nothing), so the wrapper writes `/proc/self/oom_score_adj`
  before it execs bash, which raising needs no privilege for; every process of the command inherits it.

### Each command in a scope

Built behind `--command-scopes` (`server/src/scopes.ts`, `server/test/scopes.test.ts`); as built, below the design.

The bash tool starts its command as

```
systemd-run --user --scope --quiet --unit=tau-cmd-<conversation>-<call> --slice=tau-cmd.slice \
  -p PartOf=tau-server.service -p OOMScoreAdjust=500 -- bash -c <command>
```

as an argument list, with no shell quoting (as built, without `OOMScoreAdjust=`, which a scope does not take: As
built, below). A scope inherits the caller's environment, working directory, standard
streams and process group, so the tool's pipes and its `kill(-pid)` keep working. Measured on chorus: about 3 ms per
command.

- **Lifetime, as now.** A command's background processes keep running after it returns (`npm run dev &` and a later
  `curl` work as today); the scope lasts while they do, and systemd collects it when they end.
- **Stop and timeout** stop the call's scope instead of killing its process group: the same call's processes, now
  including those that left the group (`setsid`, `nohup`, daemons). Other calls and conversations are untouched.
- **The server stopping** stops the scopes (`PartOf=`; as built `BindsTo=`, below), as stopping the service kills its cgroup now. Commands do not
  outlive the server: after a restart durable has settled their calls as interrupted and nothing would read them.
  Verified on chorus: a transient scope takes `PartOf=`, which misses a crash (As built, below).
- **Results.** When the command ends, tau reads the scope (`systemctl --user show -p Result -p MemoryPeak`); a failed
  scope stays until read, unless `--collect` is given, which tau does not. Then `reset-failed`.
- **At start** tau lists `tau-cmd-*` and settles what a crash left: reads and resets the failed, stops the running.

As built:

- **The hook: durable's `shellPath`.** `NodeExecutionEnv({ cwd, shellPath })` spawns a string command as
  `<shellPath> -c <command>` (argv, no quoting; the path must exist) with the environment the bash tool's `prepare`
  set, and on stop or timeout kills the child's process group. So tau needs no change to durable: its shellPath is a
  fixed wrapper (in `$XDG_RUNTIME_DIR/tau-commands/<slice>`, put back if a cleaner removes it), and `prepare` names the call's
  scope in `TAU_CMD_*` variables, which the wrapper unsets. The wrapper execs `systemd-run --user --scope`, which
  execs `/bin/sh` (oom_score_adj, the start mark), which execs `/bin/bash -c <command>`: one process throughout, so
  the tool's pid, pipes and process group are the command's. Without the variables (a command that is not the bash
  tool's) the wrapper refuses, exit 127.
- **The command line as given.** From systemd 254, systemd-run expands `${NAME}`, `$NAME` and `$$` in its command line
  as ExecStart= does, `--scope` included, so a command's `"$$"` reached bash as `"$"`. The wrapper passes
  `--expand-environment=no` where systemd-run has it (checked at start); older ones expand nothing in a scope.
- **Names.** `<slice less .slice>-<conversation>-<call>.scope`: `tau-cmd-12-toolu_01….scope` for `tau-cmd.slice`. A call
  ID's characters other than letters, digits, `_` and `-` are written `\xHH` (a script's nested call,
  `tool:…:…/c1`, gives `tool\x3a…\x3a…\x2fc1`); past 240 characters the ID is hashed. `--command-slice <name>.slice`
  names another slice, and so another prefix: tests and the reproduction use their own, and one server's start does
  not settle another's scopes. systemd nests a slice by its dashes: `tau-cmd.slice` lives in `tau.slice`.
- **`BindsTo=` and `After=`, not `PartOf=`**, measured on chorus with a throwaway `Restart=always` service: a
  transient scope takes `PartOf=`, and the service's stop (or restart) stops it, but its crash does not: with the
  main process killed, the scope stayed active through the automatic restart, an orphan (systemd propagates stop and
  restart jobs, not a failure). With `BindsTo=` and `After=` the scope goes inactive as soon as the service does, a
  crash included, and stays so after the restart; `After=` orders the scopes' stop before the service's. The settling
  at start stays as a backstop. The unit is the server's own (its cgroup's last component) when it runs as a
  `.service`; otherwise there is none.
- **Systemd-run failing** (a masked slice, no user manager): the start mark the wrapper writes inside the scope is
  missing, and the command fails with "The command did not start: systemd-run could not start its scope <unit>.",
  systemd-run's own error in the output above it. Nothing runs outside a scope.
- **Stop and timeout**: the scope is stopped on the call's abort signal and again when a call ends without an exit
  code (stopped, timed out, failed in the tool), so `setsid`'s escapees go with it.
- **Results** are read only for a nonzero exit; a scope whose processes all ended without failing is collected by
  systemd at once. The scope's description is "tau command": systemd's default, the command line, would put every
  command in the journal.
- Cost: a `systemd-run` per command (about 3 ms) and, for a nonzero exit, a `systemctl show`.

### What the model reads

**Built (step 3)**, before commands have scopes: tau's `afterTool` hook on bash (`server/src/commands.ts`, durable's
bash tool given a `prepare` that notes the OOM kill count when the command starts) says what the server can see:

```
Killed by SIGKILL (exit 137).
The kernel's OOM killer acted in tau-server.service while it ran.
```

- **A signal**: a shell reports a command killed by signal n as exit status 128 + n, as node does the shell's own
  death; tau names the signal in place of "Command exited with code 137", and the structured output has `signal`.
  An exit status above 128 that a program chose itself reads the same; nothing else can tell them apart.
- **The OOM killer**: the server's own cgroup (`/proc/self/cgroup`), its `memory.events` `oom_kill` counter, when the
  command started and when it ended. A rise is said as that and only that (`oomKill: true`): in the shared cgroup it
  may have killed another process than this command's.
- **A restart**: the server keeps the machine's boot ID beside its database (`tau.boot`) and reads the previous run's
  at start, so a call that durable settles as interrupted says that the machine rebooted (the boot IDs differ) or that
  the tau server restarted. Per server run rather than per call: a call is interrupted only by the run it started in
  ending. Without a previous run's ID (in memory, or the first start that keeps one) nothing is added.

`scripts/oom-repro.sh -p OOMPolicy=continue`, with step 3:

```
[driver] server restarts seen by the driver: 0
[driver] tool result (isError true):
    [error] Killed by SIGKILL (exit 137).
    [error] The kernel's OOM killer acted in tau-oomtest.service while it ran.
```

and without `OOMPolicy=continue`, where the server goes down with the command:

```
[driver] server restarts seen by the driver: 1
[driver] tool result (isError true):
    [error] Tool bash was interrupted and may have partially run
    [info] The tau server restarted while this command ran.
```

**With scopes (step 5, behind `--command-scopes`)**, killed by the OOM killer (`scripts/oom-repro.sh -s`):

```
Killed by the out-of-memory killer (exit 137).
Memory limit reached: 2.0 GiB (tau-oomtest-cmd.slice). This command's peak: 2.0 GiB.
```

The scope's `Result=oom-kill` says the OOM killer acted in it (a SIGKILL may reach the shell before systemd has read
the memory events, so tau looks again for up to a second). The limit named is the slice's when the slice's own
`memory.events.local` `oom` count rose while the command ran: its limit was reached, not a descendant's or the
machine's. A scope's own `MemoryMax=` would be named instead (tau sets none). Neither: no limit is named, the peak
only. When the OOM killer killed one of the command's processes but the shell exited otherwise: "The out-of-memory
killer killed a process of this command." beside the exit code. The structured output carries the same:
`oomKilled`, `oomKiller` (`kernel` or `systemd-oomd`), `memoryLimit` (bytes), `memoryLimitUnit`, `memoryPeak` (bytes).
Then tau resets the scope's failed state.

Killed by systemd-oomd instead (measured on chorus, systemd 259: a test slice with `ManagedOOMMemoryPressure=kill`,
`ManagedOOMMemoryPressureLimit=10%`, `ManagedOOMMemoryPressureDurationSec=2s`, `MemoryHigh=200M`, no swap, and a
hog touching 400 MB over and over; oomd killed it within 5 to 16 s, every run):

```
Killed by systemd-oomd (exit 137): memory pressure in tau-t2371361o-cmd.slice 30.69% > 10.00% for over 2s.
This command's peak: 212 MiB.
```

systemd records an oomd kill as the kernel's, `Result=oom-kill`, and tells them apart only by count: `OOMKills=0`,
`ManagedOOMKills=1` (systemd 255 has no `OOMKills`, Notes on hosts; where neither is shown tau says "Killed by an
out-of-memory kill"; where only `ManagedOOMKills` is, a kill it does not count is said to be the kernel's). The slice's own
`oom` count does not rise, as no limit was reached, so no limit is named. Why oomd killed, which watched cgroup's
pressure over what limit for how long, is only in oomd's log line ("Killed <scope> due to memory pressure for <slice>
being 31.99% > 10.00% for > 2s with reclaim activity"), which tau reads from the system journal (`journalctl
_SYSTEMD_UNIT=systemd-oomd.service`, readable by the systemd-journal group, chorus's user included) and gives with the
paths as unit names; without access to it, or for a line it does not know (oomd also kills for swap use), the first
sentence ends at the exit code. The watched cgroup need not be the command's slice: an ancestor's limit
(`user@UID.service` has Fedora's 80% for 20 s) may be the one passed.
Sizes in binary units (GiB), as systemd's are.

Interrupted by a restart (as designed; built per server run, above): the call records
`/proc/sys/kernel/random/boot_id` when it starts; if it differs after the restart,

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

As `tau setup` writes it (`~/.config/systemd/user/tau-cmd.slice`, once, then the user's): `MemoryMax=` MemTotal less a
reserve of a tenth and at least 2 GiB (chorus: 27864M of 30960M), the policy in its comments; `MemorySwapMax=0` where
`/proc/swaps` lists zram. Setup warns when the user has no linger or `user@UID.service`'s `cgroup.controllers` lacks
`memory`; `tau status` shows the slice and whether the flags have `--command-scopes`. Fedora's
`slice.d/10-oomd-per-slice-defaults.conf` gives every user slice, this one too, `ManagedOOMMemoryPressure=kill` at
80%: systemd-oomd may kill a command's scope under memory pressure before the kernel does (what the model then reads:
What the model reads).

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

**Known issue while `--command-scopes` is on** (step 4 not built, bgjob unchanged): bgjob's tmux server lands in the
scope of whichever call first starts it, and every later job of every conversation is forked into that scope. Stopping
that call while it runs, or its timeout, stops the tmux server and all jobs; their memory, and an OOM kill among them,
count to that call's scope (its peak, its `Result`); the scope lives as long as the tmux server does. A tmux server
started before the flag was turned on stays in the server's cgroup, outside the slice.

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

With `OOMPolicy=continue` (step 2, `scripts/oom-repro.sh -p OOMPolicy=continue`) the server stays:

```
[driver] server restarts seen by the driver: 0
[driver] tool result (isError true):
    [error] Command exited with code 137
== the unit
    NRestarts=0  OOMPolicy=continue
== its journal
    tau-oomtest.service: The kernel OOM killer killed some processes in this unit.
```

Only python died; the other runs went on. The model reads an exit code, still nothing about memory.

With commands in scopes (step 5, `scripts/oom-repro.sh -s`: the server with `--command-scopes --command-slice
tau-oomtest-cmd.slice`, that slice limited to `MemoryMax=2G MemorySwapMax=0` at runtime, a neighbor chat's background
`sleep` first), even with `OOMPolicy=stop`:

```
[driver] its tool result: pid 2358732
0::/user.slice/user-1000.slice/user@1000.service/tau.slice/tau-oomtest.slice/tau-oomtest-cmd.slice/tau-oomtest-cmd-3-tool\x3a1793797171243\x3athmcd79jkks.scope
[driver] server restarts seen by the driver: 0
[driver] tool result (isError true):
    [error] Killed by the out-of-memory killer (exit 137).
    [error] Memory limit reached: 2.0 GiB (tau-oomtest-cmd.slice). This command's peak: 2.0 GiB.
== the unit
    ActiveState=active  NRestarts=0  OOMPolicy=stop  MemoryPeak=122642432
== the server's own cgroup
    oom_kill 0
== the commands' scopes left
    tau-oomtest-cmd-3-tool\x3a1793797171243\x3athmcd79jkks.scope ActiveState=active Result=success
== their journal
    tau-oomtest-cmd-19-tool\x3a…scope: The kernel OOM killer killed some processes in this unit.
    tau-oomtest-cmd-19-tool\x3a…scope: Failed with result 'oom-kill'.
    tau-oomtest-cmd-19-tool\x3a…scope: Consumed 281ms CPU time over 282ms wall clock time, 1.9G memory peak.
```

The server's cgroup saw no OOM kill and did not restart; the neighbor's scope and its `sleep` live on; the hog's scope
failed alone, was read, and was reset.

## Order of work

Each step ships and reverts alone.

1. **Reproduce** (built: `scripts/oom-repro.sh`, Reproduction). On chorus, a dev tau server inside a transient unit with a small `MemoryMax`, an agent running a
   memory hog: record what the server, the unit and the model see today. The same script checks every later step.
2. **`OOMPolicy=continue`** in the unit `tau setup` writes (and in the other servers' units). Built: `scripts/tau`,
   `server/contrib/tau-server.service`; the servers set up before need the line added by hand (docs/deploy.md).
3. **The model reads what happened**: exit by signal reported as such, the boot ID check. tau code only. Built, with
   the OOM kill count of the server's cgroup (What the model reads); `server/test/commands.test.ts`.
4. **bgjob on transient services**, beside the old one until it has been used for a while.
5. **Commands in scopes**, behind a flag, on chorus first; then the default, with `tau setup` installing the slice and
   checking the user manager (linger, delegated memory controller). Built behind `--command-scopes` (off by default),
   before step 4 (the bgjob known issue); `tau setup` writes the slice and checks the user manager already.

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
