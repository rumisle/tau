// The `subagent` tool: background subagents, after durable's test/examples/23-subagent-background.ts. The model starts
// named subagents that keep working while it goes on, messages them (steer or follow-up), stops them, and asks how
// they are doing; each answer comes back to this conversation as a message of its own once it arrives. A subagent
// never blocks the conversation that started it: its conversation is owned by a background task, so this
// conversation's Stop and idle waits leave it alone. Its ID goes out in the call's details, which the app shows as a
// link into the subagent's own transcript.
import type { Context } from "@earendil-works/chord";
import { type AssistantMessage, clampThinkingLevel, type ModelThinkingLevel, Type } from "@earendil-works/pi-ai";
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
	LiveDoc,
	type ModelRef,
	type TaskId,
	type Tx,
} from "@earendil-works/pi-durable";
import { MetaDoc } from "./host.ts";

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
	/** Answers already reported: several messages can end in one answer, reported once. */
	reported: EntryId[];
};

/** The conversation's subagents by name, and the reporter of each message to them. */
const Subagents = defineDoc<{ agents: Record<string, Agent>; reporters: Record<string, TaskId> }>({
	kind: "tau.subagents",
	version: 1,
	scope: "conversation",
	history: "latest",
	// A fork starts without subagents: they belong to the original.
	fork: "initial",
	initial: () => ({ agents: {}, reporters: {} }),
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

// A reporter delivers one message to a subagent, waits for its answer, and posts the answer back. A background task
// too; request IDs make a restart neither send the message nor report the answer twice.
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
		// As a follow-up: it starts a turn when this conversation is idle, or waits for its current answer.
		report: async (reporter, runtime, taskContext) => {
			const report = reporter.state.checkpoint.report;
			if (report !== undefined) {
				const main = (await runtime.conversation(runtime.conversationId, taskContext))!;
				const input = { type: "input", content: report, whenBusy: "followUp" } as const;
				await main.submit({ ...input, requestId: `subagent-report:${reporter.id}` }, taskContext);
			}
			await runtime.commit(() => ({ status: "terminal", outcome: { status: "completed", result: null } }), taskContext);
		},
	},
	abort: (_reporter, runtime, taskContext) =>
		runtime.commit(() => ({ status: "terminal", outcome: { status: "aborted" } }), taskContext),
});

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

const subagentTool = defineTool({
	name: "subagent",
	description:
		"Run work in the background with named subagents, each with the same tools and working directory and its own " +
		"conversation. They never block you: start them, keep answering, and each answer arrives later as a message " +
		'starting with <subagent name="…">; it needs no reply unless the user should hear about it. Actions: spawn ' +
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
		model: Type.Optional(Type.String({ description: "spawn: provider/id of the model to run on; yours when omitted" })),
		thinking: Type.Optional(Type.Union(THINKING_LEVELS.map((level) => Type.Literal(level)))),
	}),
	// A call cut off by a crash is not run again: a repeated stop could stop newer work. The model sees the call was
	// interrupted and can ask with status.
	replay: "unsafe",
	execute: async (args, api, callContext: Context) => {
		const { action, name, message, followUp, fork } = args;
		let model: ModelRef | undefined;
		let thinkingLevel: ModelThinkingLevel | undefined;
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
			return reply(`Stopped ${name}.`, agent!.conversationId);
		}
		if (message === undefined || message.trim() === "") return reply(`${action} needs a message.`);

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

		const result = await api.commit(async (tx) => {
			const state = await tx.doc(Subagents, api.conversationId);
			// Tables are read before the first write.
			const at = action === "spawn" && fork === true && !Object.hasOwn(state.agents, name) ? await forkPoint(tx, api.conversationId, api.callId) : undefined;
			// Both tasks belong to this conversation and are background: its Stop and idle waits skip them.
			const background = { ownership: { kind: "conversation" }, background: true } as const;
			if (action === "spawn") {
				if (Object.hasOwn(state.agents, name)) return `${name} already exists; use send.`;
				const anchor = await tx.createTask(Anchor, null, background);
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
			}
			const conversationId = state.agents[name]!.conversationId;
			const input = { name, conversationId, message, followUp: action === "send" && followUp === true };
			state.reporters[api.taskId] = await tx.createTask(Reporter, input, background);
			return action === "send" ? `Sent to ${name}.` : `Started ${name}. Its answer will arrive as a message.`;
		}, callContext);
		const current = (await api.snapshot(Subagents, api.conversationId, callContext))?.agents[name];
		return reply(result, current?.conversationId);
	},
});

// The tasks come with the extension, so reporters still pending resume after a restart.
export const Subagent: Extension = defineExtension({ name: "subagent", tasks: [Anchor, Reporter], tools: [subagentTool] });
