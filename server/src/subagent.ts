// The `subagent` tool: background subagents, after durable's test/examples/23-subagent-background.ts. The model starts
// named subagents that keep working while it goes on, messages them (steer or follow-up), stops them, and asks how
// they are doing. A subagent never blocks the conversation that started it (its leader): its conversation is owned by
// a background task, so the leader's Stop and idle waits leave it alone. Its ID goes out in the call's details, which
// the app shows as a link into the subagent's own transcript.
//
// Every run of a subagent that answers reports its answer to the leader, whoever started the run: the leader's
// message, a steer, or the user writing in the subagent's own chat. The report is a run-end task (durable's
// `afterRun`): created with the run's end, resumed after a crash, and sent under a request ID of its answer, so it
// arrives once. A run that fails sends the leader a short note instead (`SubagentFailures`, from `pi.live.runFailure`);
// one stopped sends nothing.
import type { Context } from "@earendil-works/chord";
import { type AssistantMessage, clampThinkingLevel, type ModelThinkingLevel, Type } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
	AssistantEntry,
	type ConversationId,
	configure,
	defineDoc,
	defineExtension,
	defineTask,
	defineTool,
	type EntryId,
	type Extension,
	GenerationTask,
	type Harness,
	hook,
	LiveDoc,
	type ModelRef,
	runEndTask,
	type TaskId,
	type Tx,
} from "@earendil-works/pi-durable";
import { onCommit } from "./commits.ts";
import { MetaDoc } from "./host.ts";
import { isNested, modelCallId, SubagentEntry } from "./shown.ts";

function taskTitle(task: string): string {
	const line = task.replace(/\s+/g, " ").trim();
	if (line.length <= 48) return line;
	const cut = line.slice(0, 49);
	const space = cut.lastIndexOf(" ");
	return `${(space > 24 ? cut.slice(0, space) : line.slice(0, 48)).replace(/[,;:.\s]+$/, "")}…`;
}

function textOf(message: AssistantMessage | undefined): string {
	return (message?.content ?? []).flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

function escapeAttribute(value: string): string {
	return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

/**
 * How an answer comes back: `<subagent name="…" conversation="…" status="answered">…</subagent>`. The model reads it
 * as a report; the app shows it as the subagent's card, not as the user's message.
 */
export function subagentReport(name: string, conversationId: ConversationId, status: "answered" | "failed", text: string): string {
	return `<subagent name="${escapeAttribute(name)}" conversation="${conversationId}" status="${status}">\n${text}\n</subagent>`;
}

type Agent = {
	conversationId: ConversationId;
	/** Answers reported by `Reporter`s, the per-message reports of before run-end reports. */
	reported: EntryId[];
};

/** The conversation's subagents by name, and the `Reporter` of each message sent before run-end reports. */
const Subagents = defineDoc<{ agents: Record<string, Agent>; reporters: Record<string, TaskId> }>({
	kind: "tau.subagents",
	version: 1,
	scope: "conversation",
	history: "latest",
	// A fork starts without subagents: they belong to the original.
	fork: "initial",
	initial: () => ({ agents: {}, reporters: {} }),
	checkpointWhen: () => false,
});

// A subagent outlives this conversation's turns: its conversation is owned by an anchor, a background task that
// finishes at once. A background task is a boundary: this conversation's Stop and idle waits end there.
const Anchor = defineTask<null, { phase: "done" }, null>({
	name: "tau.subagent-anchor",
	version: 1,
	initial: () => ({ phase: "done" }),
	phases: {
		done: (_anchor, runtime, taskContext) =>
			runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), taskContext),
	},
	abort: (_anchor, runtime, taskContext) =>
		runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), taskContext),
});

/**
 * A subagent's leader, in the subagent's own conversation: whom its runs report to. Absent in a subagent started before
 * run-end reports until its leader next sends to it, and in a fork of a subagent, which reports to nobody.
 */
export const SubagentOf = defineDoc<{ leader?: ConversationId; name?: string }>({
	kind: "tau.subagent-of",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({}),
	checkpointWhen: () => false,
});

/** Every subagent with a leader (`SubagentOf`): those whose failures are checked at start. */
const SubagentsIndex = defineDoc<{ conversations: number[] }>({
	kind: "tau.subagents-index",
	version: 1,
	scope: "session",
	initial: () => ({ conversations: [] }),
	checkpointWhen: () => false,
});

// Before run-end reports, a reporter delivered one message to a subagent, waited for the answer to it, and posted it
// back, so an answer to a steer or to the user in the subagent's chat was never reported. Kept so that reporters a
// server left running finish after an upgrade; a subagent with one running keeps them until they are done.
type ReporterInput = { name: string; conversationId: ConversationId; message: string; followUp: boolean };
type ReporterState = { phase: "deliver" } | { phase: "report"; report?: string };
const Reporter = defineTask<ReporterInput, ReporterState, null>({
	name: "tau.subagent-reporter",
	version: 1,
	initial: () => ({ phase: "deliver" }),
	phases: {
		deliver: async (reporter, runtime, taskContext) => {
			const { name, conversationId, message, followUp } = reporter.input;
			const subagent = (await runtime.conversation(conversationId, taskContext))!;
			const request = { type: "input", content: message, whenBusy: followUp ? "followUp" : "steer" } as const;
			const submission = await subagent.submit({ ...request, requestId: `subagent:${reporter.id}` }, taskContext);
			const settled = await submission.wait(taskContext);
			await runtime.commit(async (tx) => {
				const next = (report?: string) => ({ status: "running", checkpoint: { phase: "report", report } }) as const;
				// Stopped, or withdrawn while queued: nothing to report.
				if (settled.status === "unanswered") {
					return next(settled.reason === "aborted" ? undefined : subagentReport(name, conversationId, "failed", `The subagent stopped: ${settled.reason}.`));
				}
				if (settled.type !== "input") return next();
				const agent = (await tx.doc(Subagents, runtime.conversationId)).agents[name]!;
				if (agent.reported.includes(settled.answer)) return next();
				agent.reported.push(settled.answer);
				const answer = (await tx.entry(AssistantEntry, settled.answer))?.model?.[0] as AssistantMessage | undefined;
				return next(subagentReport(name, conversationId, "answered", textOf(answer)));
			}, taskContext);
		},
		// As a steer: it starts a turn when this conversation is idle, or reaches it at its next step, so a conversation
		// still working reads it then, not after its whole answer.
		report: async (reporter, runtime, taskContext) => {
			const report = reporter.state.checkpoint.report;
			if (report !== undefined) {
				const main = (await runtime.conversation(runtime.conversationId, taskContext))!;
				const input = { type: "input", content: report, whenBusy: "steer" } as const;
				await main.submit({ ...input, requestId: `subagent-report:${reporter.id}` }, taskContext);
			}
			await runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), taskContext);
		},
	},
	abort: (_reporter, runtime, taskContext) =>
		runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), taskContext),
});

// A subagent's run that answered, reported to its leader: a run-end task of the run (`afterRun`), so the subagent is
// busy until the report is sent, Stop drops it, and a crash resumes it. Admitted in the task's terminal commit, under
// the answer's request ID: sent once.
type RunReportInput = { leader: ConversationId; name: string; report: string; requestId: string };
const RunReport = defineTask<RunReportInput, { phase: "report" }, null>({
	name: "tau.subagent-run-report",
	version: 1,
	initial: () => ({ phase: "report" }),
	phases: {
		report: async (task, runtime, taskContext) => {
			const leader = await runtime.conversation(task.input.leader, taskContext);
			await runtime.commit(async (tx) => {
				// As a steer: it starts a turn when the leader is idle, or reaches it at its next step, so a leader still
				// working reads it then, not after its whole answer.
				if (leader !== undefined) await leader.submit(tx, { type: "input", content: task.input.report, whenBusy: "steer", requestId: task.input.requestId });
				return { status: "terminal", outcome: { status: "completed", result: null } };
			}, taskContext);
		},
	},
	abort: (_task, runtime, taskContext) => runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), taskContext),
});

const reportAfterRun = hook(GenerationTask, {
	afterRun: async (run, api, context) => {
		const of = await api.snapshot(SubagentOf, api.conversationId, context);
		if (of?.leader === undefined || of.name === undefined) return undefined;
		const answer = (await api.entry(AssistantEntry, run.answer, context))?.model?.[0] as AssistantMessage | undefined;
		const report = subagentReport(of.name, api.conversationId, "answered", textOf(answer));
		return { tasks: [runEndTask(RunReport, { leader: of.leader, name: of.name, report, requestId: `subagent-answer:${api.conversationId}:${run.answer}` })] };
	},
});

/** How a run that ended without an answer is told to the leader; undefined for what someone did (stop, a new context). */
export function failureNote(name: string, reason: string, given: string | undefined): string | undefined {
	// A provider's error can be a whole JSON body: its start says enough.
	const detail = given === undefined || given.length <= 300 ? given : `${given.slice(0, 299)}…`;
	const why = (() => {
		switch (reason) {
			case "aborted":
			case "reset":
				return undefined;
			case "model_error":
				return `the model failed${detail === undefined ? "" : ` (${detail})`}`;
			case "no_model":
				return detail ?? "no model";
			case "interrupted":
				return "the server stopped while it was answering";
			case "restart_limit":
				return "the server stopped too many times while it ran";
			case "turn_limit":
				return `it reached its turn limit${detail === undefined ? "" : ` (${detail})`}`;
			case "nothing_to_answer":
				return "it had nothing to answer";
			case "orphaned":
				return `it could not run here${detail === undefined ? "" : ` (${detail})`}`;
			default:
				return detail ?? reason;
		}
	})();
	return why === undefined ? undefined : `${name} failed: ${why}.`;
}

type RunFailure = { taskId: number; reason: string; detail?: string };

/**
 * Tells a subagent's leader when one of its runs failed, from the subagent's `pi.live.runFailure`, which no hook
 * reports: as the commit that ends the run is stored, and at start for those a stop of the server came between (the
 * failure stays until the subagent's next run). A request ID of the failed run's task makes it arrive once.
 */
export class SubagentFailures {
	readonly #harness: Harness;
	readonly #unsubscribe: () => void;
	readonly #sent = new Set<string>();
	#closed = false;

	constructor(harness: Harness) {
		this.#harness = harness;
		this.#unsubscribe = onCommit(harness, (publication) => {
			for (const change of publication.changes) {
				if (change.type !== "document" || change.kind !== "change" || change.conversationId === undefined || change.record.kind !== LiveDoc.definition.kind) continue;
				const live = change.value as { run?: unknown; runFailure?: RunFailure };
				if (live.run !== undefined || live.runFailure === undefined) continue;
				const id = change.conversationId;
				const failure = live.runFailure;
				// Commit listeners must not call Session APIs.
				setTimeout(() => void this.#note(id, failure), 0);
			}
		});
	}

	/** The failures a stop of the server came between, as `SubagentsIndex` lists the subagents. */
	async sweep(): Promise<void> {
		const index = await this.#harness.snapshot(SubagentsIndex, BACKGROUND_CONTEXT);
		for (const id of index?.conversations ?? []) {
			const live = await this.#harness.snapshot(LiveDoc, id as ConversationId, BACKGROUND_CONTEXT);
			if (live?.run === undefined && live?.runFailure !== undefined) await this.#note(id as ConversationId, live.runFailure as RunFailure);
		}
	}

	close(): void {
		this.#closed = true;
		this.#unsubscribe();
	}

	async #note(id: ConversationId, failure: RunFailure): Promise<void> {
		const requestId = `subagent-failed:${id}:${failure.taskId}`;
		if (this.#closed || this.#sent.has(requestId)) return;
		this.#sent.add(requestId);
		try {
			const of = await this.#harness.snapshot(SubagentOf, id, BACKGROUND_CONTEXT);
			if (of?.leader === undefined || of.name === undefined) return;
			const note = failureNote(of.name, failure.reason, failure.detail);
			if (note === undefined) return;
			const leader = await this.#harness.conversation(of.leader, BACKGROUND_CONTEXT);
			const content = subagentReport(of.name, id, "failed", note);
			await leader?.submit({ type: "input", content, whenBusy: "steer", requestId }, BACKGROUND_CONTEXT);
		} catch (error) {
			this.#sent.delete(requestId);
			if (!this.#closed) console.error(`[tau] subagent ${id}: failure not reported:`, error);
		}
	}
}

const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;

/**
 * The entry a forked subagent starts from: the one before the assistant message making this call, so the copy holds the
 * whole conversation up to the request, and not the call itself, whose result it would never see.
 */
async function forkPoint(tx: Tx, conversationId: ConversationId, callId: string): Promise<EntryId | undefined> {
	let cursor: Parameters<Tx["scanEntries"]>[2];
	let found = false;
	for (let pages = 0; pages < 20; pages++) {
		const page = await tx.scanEntries({ conversationId }, 50, cursor);
		for (const entry of page.items) {
			if (found) return entry.id;
			const message = (entry as { model?: AssistantMessage[] }).model?.[0];
			if (entry.kind === "pi.assistant" && message?.content?.some((part) => part.type === "toolCall" && part.id === callId)) found = true;
		}
		if (page.next === undefined) return undefined;
		cursor = page.next;
	}
	return undefined;
}

/** Makes `leader` the subagent's leader: its runs report there from now on. */
async function lead(tx: Tx, leader: ConversationId, child: ConversationId, name: string): Promise<void> {
	const of = await tx.doc(SubagentOf, child);
	of.leader = leader;
	of.name = name;
	const index = await tx.doc(SubagentsIndex);
	if (!index.conversations.includes(child)) index.conversations.push(child);
}

const subagentTool = defineTool({
	name: "subagent",
	description:
		"Run work in the background with named subagents, each with the same tools and working directory and its own " +
		"conversation. They never block you: start them, keep answering, and each answer arrives later as a message " +
		'starting with <subagent name="…">, at your next step if you are still working; it needs no reply unless the ' +
		"user should hear about it. Actions: spawn " +
		"(name, message: the task), send (name, message; followUp: true waits for its current answer instead of " +
		"steering it), stop (name: stops its current work), status (name, or every subagent without one). Use subagents " +
		"for independent investigations that would fill this conversation with tool output; start several to work in " +
		"parallel. A spawn can take fork: true to start from a copy of this conversation, for work that needs what was " +
		"said so far; model (provider/id) and thinking to run on another model or effort, such as a fast one for search.",
	parameters: Type.Object({
		action: Type.Union([Type.Literal("spawn"), Type.Literal("send"), Type.Literal("stop"), Type.Literal("status")]),
		name: Type.Optional(Type.String({ description: "A short name, such as reader or tests" })),
		message: Type.Optional(Type.String({ description: "The task for spawn, or the message for send" })),
		followUp: Type.Optional(Type.Boolean()),
		fork: Type.Optional(Type.Boolean({ description: "spawn: start from a copy of this conversation instead of empty" })),
		model: Type.Optional(Type.String({ description: 'spawn: provider/id of the model to run on; yours when omitted. The ones available: models.getAvailableOfType("chat") in code mode' })),
		thinking: Type.Optional(Type.Union(THINKING_LEVELS.map((level) => Type.Literal(level)))),
	}),
	// A call cut off by a crash is not run again: a repeated stop could stop newer work. The model sees the call was
	// interrupted and can ask with status.
	replay: "unsafe",
	execute: async (args, api, callContext: Context) => {
		const { action, name, message, followUp, fork } = args;
		let model: ModelRef | undefined;
		let thinkingLevel: ModelThinkingLevel | undefined;
		const nested = isNested(api.callId);
		/** From a script, what the call did goes in an entry of its own (src/shown.ts), in the commit that does it. */
		const show = async (tx: Tx, conversationId: ConversationId) => {
			if (!nested || action === "status" || name === undefined) return;
			await tx.appendEntry(SubagentEntry, api.conversationId, {
				data: {
					callId: api.callId,
					action,
					name,
					...(message === undefined || action === "stop" ? {} : { message }),
					conversationId,
					...(model === undefined ? {} : { model: `${model.provider}/${model.modelId}` }),
					...(thinkingLevel === undefined ? {} : { thinking: thinkingLevel }),
					...(fork === true ? { fork: true as const } : {}),
					at: api.now(),
				},
			});
		};
		const reply = (text: string, conversationId?: ConversationId) => ({
			output: [{ type: "text" as const, text }],
			...(conversationId === undefined || name === undefined
				? {}
				: { details: { name, conversationId, action, ...(model === undefined ? {} : { model: `${model.provider}/${model.modelId}` }), ...(thinkingLevel === undefined ? {} : { thinking: thinkingLevel }), ...(fork === true ? { fork: true } : {}) } }),
		});
		const registry = (await api.snapshot(Subagents, api.conversationId, callContext)) ?? { agents: {}, reporters: {} };

		if (action === "status") {
			const names = name === undefined ? Object.keys(registry.agents) : [name];
			const lines: string[] = [];
			for (const each of names) {
				const found = Object.hasOwn(registry.agents, each) ? registry.agents[each] : undefined;
				if (found === undefined) continue;
				const busy = (await api.snapshot(LiveDoc, found.conversationId, callContext))?.run !== undefined;
				lines.push(`${each}: ${busy ? "working" : "idle"}`);
			}
			return reply(lines.length === 0 ? "No subagents." : lines.join("\n"));
		}
		if (name === undefined || name.trim() === "") return reply(`${action} needs a name.`);
		const agent = Object.hasOwn(registry.agents, name) ? registry.agents[name] : undefined;
		if (action !== "spawn" && agent === undefined) return reply(`No subagent named ${name}.`);

		if (action === "stop") {
			await (await api.conversation(agent!.conversationId, callContext))!.abort(callContext);
			if (nested) await api.commit((tx) => show(tx, agent!.conversationId), callContext);
			return reply(`Stopped ${name}.`, agent!.conversationId);
		}
		if (message === undefined || message.trim() === "") return reply(`${action} needs a message.`);
		const text = message;

		// Another model or effort: one the server has credentials for, at a level it has (pi's clampThinkingLevel).
		if (action === "spawn" && (args.model !== undefined || args.thinking !== undefined)) {
			const available = await api.models.getAvailable();
			let found = available.find((each) => args.model === undefined || `${each.provider}/${each.id}` === args.model || each.id === args.model);
			if (args.model === undefined) {
				const own = (await api.agent(callContext)).model;
				found = own === undefined ? undefined : api.models.getModel(own.provider, own.modelId);
			} else if (found === undefined) {
				const names = available.slice(0, 40).map((each) => `${each.provider}/${each.id}`);
				return reply(`No model ${args.model}. Available: ${names.join(", ")}.`);
			}
			if (found !== undefined && args.model !== undefined) model = { provider: found.provider, modelId: found.id };
			if (args.thinking !== undefined) thinkingLevel = found === undefined ? args.thinking : clampThinkingLevel(found, args.thinking);
		}

		type Created = { error: string } | { conversationId: ConversationId; reporter: boolean };
		const created = await api.commit(async (tx): Promise<Created> => {
			const state = await tx.doc(Subagents, api.conversationId);
			// Tables are read before the first write.
			// From a script, the call the model made: the script's.
			const at = action === "spawn" && fork === true && !Object.hasOwn(state.agents, name) ? await forkPoint(tx, api.conversationId, modelCallId(api.callId)) : undefined;
			if (action === "spawn") {
				if (Object.hasOwn(state.agents, name)) return { error: `${name} already exists; use send.` };
				// Owned by a background task of this conversation: its Stop and idle waits skip it.
				const anchor = await tx.createTask(Anchor, null, { ownership: { kind: "conversation" }, background: true });
				// Owned by a task of this conversation: it starts as a copy of this agent, and with fork, of its transcript.
				const ownership = { kind: "task", taskId: anchor } as const;
				const child = at === undefined ? await tx.createConversation({ ownership }) : await tx.forkConversation(api.conversationId, at, { ownership });
				await configure(tx, child.id, {
					extensions: { remove: [Subagent] },
					instructions:
						`You are the subagent "${name}". Do the task you are given and answer with what you found.` +
						(at === undefined ? "" : " The conversation before the task is the one you were started from."),
					...(model === undefined ? {} : { model }),
					...(thinkingLevel === undefined ? {} : { thinkingLevel: thinkingLevel === "off" ? null : thinkingLevel }),
				});
				(await tx.doc(MetaDoc, child.id)).title = `${name}: ${taskTitle(message)}`;
				state.agents[name] = { conversationId: child.id, reported: [] };
				await lead(tx, api.conversationId, child.id, name);
				return { conversationId: child.id, reporter: false };
			}
			const conversationId = state.agents[name]!.conversationId;
			// A subagent started before run-end reports, with a reporter still waiting on it: its messages go on through
			// reporters, else it would report one answer twice. Without one, it reports its runs from now on.
			const of = await tx.doc(SubagentOf, conversationId);
			if (of.leader === undefined) {
				for (const reporter of Object.values(state.reporters)) {
					const record = await tx.task(reporter);
					const input = record?.input as ReporterInput | undefined;
					if (input?.conversationId === conversationId && record!.state.status !== "terminal" && record!.state.status !== "completing") {
						state.reporters[api.taskId] = await tx.createTask(Reporter, { name, conversationId, message, followUp: followUp === true }, { ownership: { kind: "conversation" }, background: true });
						await show(tx, conversationId);
						return { conversationId, reporter: true };
					}
				}
				await lead(tx, api.conversationId, conversationId, name);
			}
			return { conversationId, reporter: false };
		}, callContext);
		if ("error" in created) return reply(created.error);

		const { conversationId } = created;
		if (!created.reporter) {
			// The message, admitted with what the call shows, under the call's request ID: a call cut off after it is not
			// run again (replay: "unsafe").
			const subagent = (await api.conversation(conversationId, callContext))!;
			await api.commit(async (tx) => {
				const whenBusy = action === "send" && followUp === true ? "followUp" : "steer";
				await subagent.submit(tx, { type: "input", content: text, whenBusy, requestId: `subagent:${api.taskId}` });
				await show(tx, conversationId);
			}, callContext);
		}
		const result = action === "send" ? `Sent to ${name}.` : `Started ${name}. Its answer will arrive as a message.`;
		const current = (await api.snapshot(Subagents, api.conversationId, callContext))?.agents[name];
		return reply(result, current?.conversationId);
	},
});

// The tasks come with the extension, so reporters still pending resume after a restart.
export const Subagent: Extension = defineExtension({ name: "subagent", tasks: [Anchor, Reporter], tools: [subagentTool] });

// The report of a subagent's runs: in an extension of its own, which subagents keep (they leave out `subagent`).
export const SubagentReports: Extension = defineExtension({ name: "subagent-reports", tasks: [RunReport], hooks: [reportAfterRun] });
