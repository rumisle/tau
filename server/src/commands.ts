// What the model reads when a command did not end on its own (docs/command-isolation.md, "What the model reads"): facts
// the server can see, no guesses. durable's bash tool reports any nonzero exit as "Command exited with code N"; tau's
// `afterTool` hook adds what is known about how it ended:
//
// - Killed by a signal: a shell reports a command killed by signal n as exit status 128 + n, and node does the same
//   for the shell itself; "Killed by SIGKILL (exit 137)." in place of the exit code, `signal` in the structured output.
// - The kernel's OOM killer acted in the server's cgroup while the command ran: its `memory.events` oom_kill counter
//   rose. Said as that, `oomKill: true`: in a shared cgroup it need not have been this command's process it killed.
// - Interrupted by a restart: the boot ID the previous server run wrote beside the database, against the machine's
//   now. The machine rebooted, or the tau server restarted.
// - With commands in scopes (src/scopes.ts, --command-scopes), what the call's scope says: killed by the OOM killer,
//   the limit reached and the command's peak; or that systemd-run could not start it.
import { readFileSync, writeFileSync } from "node:fs";
import { constants } from "node:os";
import { basename } from "node:path";
import { defineExtension, type Extension, hook, type HookRegistration, type ToolDiagnostic, type ToolExecutionResult, ToolTask } from "@earendil-works/pi-durable";
import { createBashTool, createEditTool, createReadTool, createWriteTool, type BashPrepare, type ImageProcessor } from "@earendil-works/pi-durable/tools";
import type { CommandScopes } from "./scopes.ts";

export type CommandFactsOptions = {
	/** Where this server run's boot ID is kept for the next one: beside the database; none in memory. */
	bootFile?: string;
	/** The machine's boot ID; `TAU_BOOT_ID_PATH` for tests, else the kernel's. */
	bootIdPath?: string;
	/** The server's own cgroup, as `/proc/self/cgroup` names it, and where cgroups are mounted (tests fake both). */
	procCgroup?: string;
	cgroupRoot?: string;
	/** Each command in its own scope (--command-scopes). */
	scopes?: CommandScopes;
};

const NAMES = new Map(Object.entries(constants.signals).map(([name, number]) => [number, name]));

/** The signal a shell's exit status says killed the command: 128 + n for a signal n. */
export function signalOf(exitCode: number): string | undefined {
	return exitCode > 128 ? NAMES.get(exitCode - 128) : undefined;
}

function read(path: string): string | undefined {
	try {
		return readFileSync(path, "utf8").trim();
	} catch {
		return undefined;
	}
}

export class CommandFacts {
	/** The boot ID the previous server run wrote, if any; undefined in memory or before the first run that kept one. */
	readonly previousBoot: string | undefined;
	readonly boot: string | undefined;
	readonly #events: string | undefined;
	/** The server's unit, as the facts name it: its cgroup's last component (`tau-server.service`). */
	readonly unit: string | undefined;
	/** The OOM kill count when each running call started, by conversation and call. */
	readonly #started = new Map<string, number>();
	readonly scopes: CommandScopes | undefined;

	constructor(options: CommandFactsOptions = {}) {
		this.scopes = options.scopes;
		this.boot = read(options.bootIdPath ?? process.env.TAU_BOOT_ID_PATH ?? "/proc/sys/kernel/random/boot_id");
		if (options.bootFile !== undefined) {
			this.previousBoot = read(options.bootFile);
			if (this.boot !== undefined) {
				try {
					writeFileSync(options.bootFile, `${this.boot}\n`);
				} catch (error) {
					console.error("[tau] boot ID not kept:", error);
				}
			}
		}
		// cgroup v2: one line, "0::<path>".
		const path = read(options.procCgroup ?? "/proc/self/cgroup")?.split("\n").find((line) => line.startsWith("0::"))?.slice(3);
		if (path !== undefined) {
			this.#events = `${options.cgroupRoot ?? "/sys/fs/cgroup"}${path === "/" ? "" : path}/memory.events`;
			this.unit = basename(path) || undefined;
		}
	}

	/** Processes the OOM killer killed in the server's cgroup so far; undefined where that cannot be read. */
	oomKills(): number | undefined {
		if (this.#events === undefined) return undefined;
		const count = read(this.#events)?.match(/^oom_kill (\d+)$/m)?.[1];
		return count === undefined ? undefined : Number(count);
	}

	/** durable's bash `prepare`: notes the count as the command starts. */
	readonly prepare: BashPrepare = async (execution, api, context) => {
		const count = this.oomKills();
		if (count !== undefined) this.#started.set(`${api.conversationId}/${api.callId}`, count);
		await this.scopes?.prepare(execution, api, context);
	};

	/** The facts of a finished bash call, added to its result. */
	explain(conversationId: number, callId: string, result: ToolExecutionResult): ToolExecutionResult {
		const key = `${conversationId}/${callId}`;
		const started = this.#started.get(key);
		this.#started.delete(key);
		const diagnostics: ToolDiagnostic[] = [...(result.diagnostics ?? [])];
		let structured = result.structuredOutput as Record<string, unknown> | undefined;
		let changed = false;
		const exited = diagnostics.findIndex((diagnostic) => diagnostic.code === "exit_code");
		const exitCode = typeof structured?.exitCode === "number" ? structured.exitCode : Number(/(\d+)$/.exec(diagnostics[exited]?.message ?? "")?.[1] ?? Number.NaN);
		const signal = Number.isInteger(exitCode) ? signalOf(exitCode) : undefined;
		if (signal !== undefined && exited !== -1) {
			diagnostics[exited] = { ...diagnostics[exited]!, message: `Killed by ${signal} (exit ${exitCode}).` };
			if (structured !== undefined) structured = { ...structured, signal };
			changed = true;
		}
		const now = started === undefined ? undefined : this.oomKills();
		if (started !== undefined && now !== undefined && now > started) {
			diagnostics.push({ severity: "error", code: "oom_kill", message: `The kernel's OOM killer acted in ${this.unit ?? "the tau server's cgroup"} while it ran.` });
			if (structured !== undefined) structured = { ...structured, oomKill: true };
			changed = true;
		}
		if (diagnostics.some((diagnostic) => diagnostic.code === "interrupted") && this.previousBoot !== undefined && this.boot !== undefined) {
			const message = this.previousBoot !== this.boot ? "The machine rebooted while this command ran (boot ID changed)." : "The tau server restarted while this command ran.";
			diagnostics.push({ severity: "info", code: "restart", message });
			changed = true;
		}
		if (!changed) return result;
		return { ...result, diagnostics, ...(structured === undefined ? {} : { structuredOutput: structured as never }) };
	}

	/** `explain`, then what the call's scope says, when commands have scopes. */
	async finish(conversationId: number, callId: string, result: ToolExecutionResult): Promise<ToolExecutionResult> {
		const explained = this.explain(conversationId, callId, result);
		return this.scopes === undefined ? explained : this.scopes.finish(conversationId, callId, explained);
	}

	readonly hook: HookRegistration = hook(ToolTask, {
		afterTool: (call, result, api) => (call.name === "bash" ? this.finish(api.conversationId, call.id, result) : undefined),
	});
}

/**
 * durable's coding tools (its `createCodingTools`, under the same extension name, which conversations' agents name), with
 * bash prepared and explained by `facts`.
 */
export function codingTools(images: ImageProcessor, facts: CommandFacts): Extension {
	return defineExtension({
		name: "coding-tools",
		tools: [createReadTool({ images }), createWriteTool(), createEditTool(), createBashTool({ prepare: facts.prepare })],
		hooks: [facts.hook],
	});
}
