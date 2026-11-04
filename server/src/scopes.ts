// Each bash command in its own transient systemd scope (docs/command-isolation.md, "Each command in a scope"), with
// `--command-scopes`. durable's NodeExecutionEnv runs a command as `<shellPath> -c <command>`; tau gives it a fixed
// wrapper as shellPath, and the bash tool's `prepare` names the call's scope in the command's environment. The wrapper
// execs `systemd-run --user --scope`, which execs the command in the same process: the tool's pipes, its process group
// and its kill of that group work as without scopes, and the arguments reach bash as durable gave them, unquoted.
//
// - The scope: `<prefix><conversation>-<call>.scope` (`tau-cmd-12-toolu_01….scope`), in the slice (`tau-cmd.slice`,
//   whose name less `.slice` is the prefix), `BindsTo=` and `After=` the server's unit (stopped when it stops or
//   crashes; `PartOf=` misses a crash), its OOM score raised to 500 by the wrapper
//   (systemd does not take `OOMScoreAdjust=` for a transient scope).
// - Stop and timeout: the call's scope is stopped, every process in it, those that left its process group too.
// - Killed by the OOM killer: systemd keeps the failed scope; tau reads its Result and MemoryPeak, and the slice's
//   memory events for whether the slice's limit was reached, says those facts, and resets the unit's failed state.
// - systemd-run failing: the command did not start, which its result says; there is no fallback to running it
//   outside a scope.
// - At start tau stops what a crash left running of its scopes and resets the failed.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { ToolDiagnostic, ToolExecutionResult } from "@earendil-works/pi-durable";
import type { BashPrepare } from "@earendil-works/pi-durable/tools";

/** The OOM score commands get: the kernel prefers them to the server (which cannot lower its own). */
export const COMMAND_OOM_SCORE = 500;

const WRAPPER = `#!/bin/sh
# tau's command shell (server/src/scopes.ts, --command-scopes). durable's bash tool runs \`<this> -c <command>\`;
# this starts it in the transient scope tau named for the call, the arguments passed on as they are.
unit=$TAU_CMD_UNIT slice=$TAU_CMD_SLICE bound_to=$TAU_CMD_BOUND_TO started=$TAU_CMD_STARTED
unset TAU_CMD_UNIT TAU_CMD_SLICE TAU_CMD_BOUND_TO TAU_CMD_STARTED
if [ -z "$unit" ] || [ -z "$slice" ] || [ -z "$started" ]; then
	echo "tau: this shell runs only the bash tool's commands, each in the scope tau names for it" >&2
	exit 127
fi
set -- --slice="$slice" -- /bin/sh -c 'echo ${COMMAND_OOM_SCORE} > /proc/self/oom_score_adj 2>/dev/null; : > "$0" && exec /bin/bash "$@"' "$started" "$@"
if [ -n "$bound_to" ]; then set -- -p "BindsTo=$bound_to" -p "After=$bound_to" "$@"; fi
# A description of its own: systemd's default, the command line, would put every command in the journal.
exec systemd-run --user --scope --quiet --unit="$unit" --description="tau command" "$@"
`;

/** A unit name's part for `text`: characters other than letters, digits, `_` and `-` as `\xHH` of their UTF-8 bytes. */
export function escapeUnitPart(text: string): string {
	let escaped = "";
	for (const byte of Buffer.from(text, "utf8")) {
		const char = String.fromCharCode(byte);
		escaped += /[A-Za-z0-9_-]/.test(char) ? char : `\\x${byte.toString(16).padStart(2, "0")}`;
	}
	return escaped;
}

/** The scope of a call: `<prefix><conversation>-<call>.scope`, the call ID escaped, hashed past a unit name's length. */
export function scopeUnit(prefix: string, conversationId: number, callId: string): string {
	const name = `${prefix}${conversationId}-${escapeUnitPart(callId)}`;
	if (name.length <= 240) return `${name}.scope`;
	return `${prefix}${conversationId}-${createHash("sha256").update(callId).digest("hex").slice(0, 32)}.scope`;
}

export type CommandScopesOptions = {
	/** The slice every scope is in; default `tau-cmd.slice`. Its name less `.slice` and a `-` prefix the scopes'. */
	slice?: string;
	/** The unit the scopes are `BindsTo=` and `After=`; default the server's own when it runs as a service, else none. */
	boundTo?: string;
	/** Where the wrapper and the calls' start marks are kept; default `$XDG_RUNTIME_DIR/tau-commands/<slice>`, one per slice
	 * so that a server that crashed leaves only the next one's. */
	dir?: string;
};

type Running = { unit: string; started: string; sliceOoms: number; stopOnAbort: () => void; signal: AbortSignal | undefined };

/** `systemctl --user <args>`: its output, or the error it failed with. */
function systemctl(args: readonly string[]): Promise<{ ok: boolean; stdout: string; stderr: string }> {
	return new Promise((resolve) => {
		execFile("systemctl", ["--user", ...args], { timeout: 30_000 }, (error, stdout, stderr) => resolve({ ok: error === null, stdout, stderr }));
	});
}

async function show(unit: string, properties: readonly string[]): Promise<Record<string, string>> {
	const { stdout } = await systemctl(["show", unit, ...properties.flatMap((property) => ["-p", property])]);
	return Object.fromEntries(stdout.split("\n").flatMap((line) => {
		const at = line.indexOf("=");
		return at === -1 ? [] : [[line.slice(0, at), line.slice(at + 1)]];
	}));
}

/** A byte count as the model reads it: `26.0 GiB`, `512 MiB`. */
export function formatBytes(bytes: number): string {
	const units = ["B", "KiB", "MiB", "GiB", "TiB"];
	let value = bytes;
	let unit = 0;
	while (value >= 1024 && unit < units.length - 1) {
		value /= 1024;
		unit++;
	}
	return unit === 0 ? `${bytes} B` : `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

const bytes = (value: string | undefined) => (value !== undefined && /^\d+$/.test(value) ? Number(value) : undefined);

function serverUnit(): string | undefined {
	try {
		const path = readFileSync("/proc/self/cgroup", "utf8").split("\n").find((line) => line.startsWith("0::"))?.slice(3);
		const name = path === undefined ? undefined : basename(path);
		return name?.endsWith(".service") ? name : undefined;
	} catch {
		return undefined;
	}
}

export class CommandScopes {
	readonly slice: string;
	/** Every scope's name starts with it: the slice's name less `.slice`, and `-`. */
	readonly prefix: string;
	readonly boundTo: string | undefined;
	readonly dir: string;
	/** The wrapper NodeExecutionEnv runs as its shell. */
	readonly shellPath: string;
	readonly #ownDir: boolean;
	readonly #running = new Map<string, Running>();
	/** The slice's cgroup, once it has one (it is created with its first scope). */
	#sliceCgroup: string | undefined;

	private constructor(options: CommandScopesOptions) {
		this.slice = options.slice ?? "tau-cmd.slice";
		if (!/^[A-Za-z0-9_-]+\.slice$/.test(this.slice)) throw new Error(`Not a slice name: ${this.slice}`);
		this.prefix = `${this.slice.slice(0, -".slice".length)}-`;
		this.boundTo = options.boundTo ?? serverUnit();
		this.#ownDir = options.dir === undefined;
		this.dir = options.dir ?? join(process.env.XDG_RUNTIME_DIR ?? tmpdir(), "tau-commands", this.slice);
		mkdirSync(this.dir, { recursive: true, mode: 0o700 });
		this.shellPath = join(this.dir, "command-shell");
		this.#writeWrapper();
	}

	/** The scopes, after settling what a previous server run left of them. */
	static async open(options: CommandScopesOptions = {}): Promise<CommandScopes> {
		const scopes = new CommandScopes(options);
		const { stopped, reset } = await scopes.reconcile();
		if (stopped.length > 0 || reset.length > 0) console.error(`[tau] command scopes a previous run left: stopped ${stopped.length}, reset ${reset.length}`);
		return scopes;
	}

	#writeWrapper(): void {
		writeFileSync(this.shellPath, WRAPPER);
		chmodSync(this.shellPath, 0o755);
	}

	unit(conversationId: number, callId: string): string {
		return scopeUnit(this.prefix, conversationId, callId);
	}

	/** Stops what a crash left of this prefix's scopes and resets the failed (a stopped server's are stopped already). */
	async reconcile(): Promise<{ stopped: string[]; reset: string[] }> {
		const listed = await systemctl(["list-units", "--all", "--plain", "--no-legend", "--type=scope", `${this.prefix}*`]);
		const stopped: string[] = [];
		const reset: string[] = [];
		for (const line of listed.stdout.split("\n")) {
			const [unit, , active] = line.trim().split(/\s+/);
			if (unit === undefined || !unit.startsWith(this.prefix) || !unit.endsWith(".scope")) continue;
			if (active === "active" || active === "activating" || active === "deactivating") {
				await systemctl(["stop", unit]);
				stopped.push(unit);
			}
			await systemctl(["reset-failed", unit]);
			if (active === "failed") reset.push(unit);
		}
		return { stopped, reset };
	}

	/** The OOM count of the slice itself (`memory.events.local`): times its own limit was reached. 0 before it exists. */
	async #sliceOoms(): Promise<number> {
		if (this.#sliceCgroup === undefined) {
			const cgroup = (await show(this.slice, ["ControlGroup"])).ControlGroup;
			if (cgroup === undefined || cgroup === "") return 0;
			this.#sliceCgroup = cgroup;
		}
		try {
			const events = readFileSync(`/sys/fs/cgroup${this.#sliceCgroup}/memory.events.local`, "utf8");
			return Number(/^oom (\d+)$/m.exec(events)?.[1] ?? 0);
		} catch {
			return 0;
		}
	}

	/** durable's bash `prepare`: names the call's scope in the command's environment for the wrapper. */
	readonly prepare: BashPrepare = async (execution, api, context) => {
		// The wrapper lives in a temporary directory, which a cleaner may empty; it is tau's own, so it is put back.
		if (!existsSync(this.shellPath)) this.#writeWrapper();
		const unit = this.unit(api.conversationId, api.callId);
		const started = join(this.dir, `${unit}.started`);
		rmSync(started, { force: true });
		const key = `${api.conversationId}/${api.callId}`;
		const signal = context.abortSignal;
		const stopOnAbort = () => void systemctl(["stop", unit]);
		signal?.addEventListener("abort", stopOnAbort, { once: true });
		this.#running.set(key, { unit, started, sliceOoms: await this.#sliceOoms(), stopOnAbort, signal });
		execution.env.TAU_CMD_UNIT = unit;
		execution.env.TAU_CMD_SLICE = this.slice;
		execution.env.TAU_CMD_BOUND_TO = this.boundTo ?? "";
		execution.env.TAU_CMD_STARTED = started;
	};

	/**
	 * A finished bash call's result with what its scope says: that it did not start in one, that the OOM killer
	 * killed it (and which limit was reached, its peak); a call that did not exit (stopped, timed out) has its scope
	 * stopped. A failed scope's state is reset once read.
	 */
	async finish(conversationId: number, callId: string, result: ToolExecutionResult): Promise<ToolExecutionResult> {
		const key = `${conversationId}/${callId}`;
		const running = this.#running.get(key);
		if (running === undefined) return result;
		this.#running.delete(key);
		running.signal?.removeEventListener("abort", running.stopOnAbort);
		const { unit } = running;
		const began = existsSync(running.started);
		rmSync(running.started, { force: true });
		const structured = result.structuredOutput as Record<string, unknown> | undefined;
		const exitCode = typeof structured?.exitCode === "number" ? structured.exitCode : undefined;
		const diagnostics: ToolDiagnostic[] = [...(result.diagnostics ?? [])];

		if (exitCode === undefined) {
			// Stopped, timed out, or failed in the tool: the call is over, so is its scope.
			await systemctl(["stop", unit]);
			await systemctl(["reset-failed", unit]);
			return result;
		}
		if (!began) {
			// systemd-run's own error is in the output.
			diagnostics.push({ severity: "error", code: "scope_failed", message: `The command did not start: systemd-run could not start its scope ${unit}.` });
			return { ...result, isError: true, diagnostics };
		}
		if (exitCode === 0) return result;

		let state = await show(unit, ["ActiveState", "Result", "MemoryPeak", "MemoryMax"]);
		// The OOM killer's SIGKILL may reach the shell before systemd has seen the scope's memory events.
		for (let tries = 0; exitCode === 137 && state.Result !== "oom-kill" && state.ActiveState === "active" && tries < 10; tries++) {
			await new Promise((resolve) => setTimeout(resolve, 100));
			state = await show(unit, ["ActiveState", "Result", "MemoryPeak", "MemoryMax"]);
		}
		if (state.ActiveState === "failed") await systemctl(["reset-failed", unit]);
		if (state.Result !== "oom-kill") return result;

		const peak = bytes(state.MemoryPeak);
		const sliceReached = (await this.#sliceOoms()) > running.sliceOoms;
		const scopeLimit = bytes(state.MemoryMax);
		const sliceLimit = sliceReached ? bytes((await show(this.slice, ["MemoryMax"])).MemoryMax) : undefined;
		const [limit, limitUnit] = sliceReached && sliceLimit !== undefined ? [sliceLimit, this.slice] : scopeLimit !== undefined ? [scopeLimit, unit] : [undefined, undefined];

		const exited = diagnostics.findIndex((diagnostic) => diagnostic.code === "exit_code");
		const killed = { severity: "error", code: "oom_kill", message: `Killed by the out-of-memory killer (exit ${exitCode}).` } as const;
		if (exitCode === 137 && exited !== -1) diagnostics[exited] = killed;
		else diagnostics.push({ severity: "error", code: "oom_kill", message: "The out-of-memory killer killed a process of this command." });
		const parts = [
			...(limit === undefined ? [] : [`Memory limit reached: ${formatBytes(limit)} (${limitUnit}).`]),
			...(peak === undefined ? [] : [`This command's peak: ${formatBytes(peak)}.`]),
		];
		if (parts.length > 0) diagnostics.push({ severity: "error", code: "memory", message: parts.join(" ") });
		return {
			...result,
			diagnostics,
			structuredOutput: {
				...structured,
				oomKilled: true,
				...(limit === undefined ? {} : { memoryLimit: limit, memoryLimitUnit: limitUnit }),
				...(peak === undefined ? {} : { memoryPeak: peak }),
			} as never,
		};
	}

	close(): void {
		if (this.#ownDir) rmSync(this.dir, { recursive: true, force: true });
	}
}
