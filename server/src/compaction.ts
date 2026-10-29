// Compaction as durable does it (harness/compaction.ts), with two changes: when it starts, and how the summary is asked
// for. Durable starts a background compaction `backgroundTokens` before the blocking threshold, `reserveTokens` short
// of the window; tau starts it at a share of the window with a cap (90%, never past 700k tokens: past that, long
// context quality and the price of every step argue for compacting even in a larger window), and keeps durable's
// blocking threshold as the backstop. And durable summarizes in a request of its own, the old messages serialized as
// text, which reads nothing from the prompt cache; tau sends the conversation's own request again, exactly as its last
// step sent it, with the summary prompt after it, so the whole context is a cache read and only the summary is new.
//
// The request goes out from durable's `beforeCompact` hook, which may supply the summary. Durable still selects what is
// kept, places the summary entry, and owns the task. Anything that does not give a summary (no cached context to
// follow, a reply with a tool call or no text, an error that persists) declines to decide, and durable's own
// summarization runs: the fallback is the default.
import type { Context } from "@earendil-works/chord";
import type { AssistantMessage, Message, Models, SimpleStreamOptions, Usage } from "@earendil-works/pi-ai";
import { isRetryableAssistantError, retryDelayMs } from "@earendil-works/pi-ai/utils/retry";
import {
	type CompactionPolicy,
	CompactionTask,
	type ContextView,
	type ConversationId,
	type EntryId,
	type Harness,
	type HookRegistration,
	hook,
	ProviderDoc,
	UsageDoc,
} from "@earendil-works/pi-durable";

/** When compaction starts: `ratio` of the model's window, but never past `maxTokens`. */
export type CompactionThreshold = { enabled: boolean; ratio: number; maxTokens: number };
export const DEFAULT_COMPACTION_THRESHOLD: CompactionThreshold = { enabled: true, ratio: 0.9, maxTokens: 700_000 };
/** What a client may set: compacting at a tenth of the window would keep little, and a smaller cap than this, less. */
export const MIN_COMPACTION_RATIO = 0.3;
export const MAX_COMPACTION_RATIO = 0.95;
export const MIN_COMPACTION_TOKENS = 32_000;

/** Durable's room for the answer (`DEFAULT_COMPACTION_POLICY.reserveTokens`): above it, generation waits for a summary. */
const RESERVE_TOKENS = 16_384;
/** Attempts of the follow-up request on errors that may pass, before durable's summarization takes over. */
const MAX_ATTEMPTS = 3;

/**
 * The policy for a model with `contextWindow`: background compaction from the threshold, blocking at durable's
 * threshold. A window too small for the threshold to come first only blocks, as durable does without background.
 */
export function compactionPolicy(contextWindow: number, threshold: CompactionThreshold): Partial<CompactionPolicy> {
	if (!threshold.enabled) return { enabled: false };
	const start = Math.min(Math.floor(contextWindow * threshold.ratio), threshold.maxTokens);
	const blocking = contextWindow - RESERVE_TOKENS;
	return { enabled: true, reserveTokens: RESERVE_TOKENS, backgroundTokens: Math.max(0, blocking - start) };
}

/**
 * `modelOverrides` for every model `models` knows, over `base` (per-model settings of their own, which win field by
 * field). Keyed as durable keys them, `provider/modelId`.
 */
export function compactionOverrides(
	models: Models,
	threshold: CompactionThreshold,
	base: Readonly<Record<string, Partial<CompactionPolicy>>> = {},
): Record<string, Partial<CompactionPolicy>> {
	const overrides: Record<string, Partial<CompactionPolicy>> = {};
	for (const model of models.getModels()) {
		if (!(model.contextWindow > 0)) continue;
		const key = `${model.provider}/${model.id}`;
		overrides[key] = { ...compactionPolicy(model.contextWindow, threshold), ...base[key] };
	}
	for (const [key, policy] of Object.entries(base)) overrides[key] ??= { ...policy };
	return overrides;
}

/** The first words of the follow-up, by which the dev model knows it (src/dev-model.ts). */
export const FOLLOW_UP_OPENING = "This message is not from the user: the conversation is being compacted.";

/**
 * Durable's summarization prompt (SUMMARIZATION_PROMPT and SUMMARIZATION_SYSTEM_PROMPT), worded for a reader that has
 * the whole conversation in its context, not a transcript of the part to summarize: it names where the kept part
 * starts. The system prompt cannot change without missing the cache, so its instructions open the message.
 */
export function followUpPrompt(kept: string, instructions?: string): string {
	const focus = instructions === undefined ? "" : `\n\nAdditional focus: ${instructions}`;
	return `${FOLLOW_UP_OPENING} Everything before ${kept} will be replaced by a summary, and the conversation from there on stays as it is, after the summary. Write that summary now, as your whole reply.

Do NOT continue the conversation. Do NOT call tools. Do NOT respond to any questions in the conversation. ONLY output the structured summary.

Create a structured context checkpoint summary that another LLM will use to continue the work. Summarize in detail what came before ${kept}; for Progress and Next Steps, describe the state as of the end of the conversation. If the conversation starts with an earlier summary, preserve its information and fold the newer messages into it.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.${focus}`;
}

/** What one follow-up cost, for the usage ledger. */
export type CompactionUsage = { conversationId: ConversationId; time: number; model: string; usage: Usage; taskId?: number };

export class FollowUpCompaction {
	#harness?: Harness;
	readonly #listeners = new Set<(record: CompactionUsage) => void>();
	readonly #retry: () => { baseDelayMs: number; maxAgentDelayMs?: number };
	readonly #stream: () => SimpleStreamOptions;
	readonly #now: () => number;

	/** `retry` and `stream` as the harness settings have them: the follow-up goes out as the conversation's requests do. */
	constructor(options: { retry: () => { baseDelayMs: number; maxAgentDelayMs?: number }; stream?: () => SimpleStreamOptions; now?: () => number }) {
		this.#retry = options.retry;
		this.#stream = options.stream ?? (() => ({}));
		this.#now = options.now ?? Date.now;
	}

	attach(harness: Harness): void {
		this.#harness = harness;
	}

	onUsage(listener: (record: CompactionUsage) => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	readonly hook: HookRegistration = hook(CompactionTask, {
		beforeCompact: async (compaction, api, context) => {
			// The compaction task asking: what its summary costs is its own (src/compactions.ts).
			const taskId = (api as { taskId?: number }).taskId;
			const summary = await this.#summarize(api.conversationId, api.models, compaction.firstKept, compaction.instructions, context, taskId);
			return summary === undefined ? undefined : { summary };
		},
	});

	async #summarize(id: ConversationId, models: Models, firstKept: EntryId, instructions: string | undefined, context: Context, taskId?: number): Promise<string | undefined> {
		const harness = this.#harness;
		const conversation = await harness?.conversation(id, context);
		if (harness === undefined || conversation === undefined) return undefined;
		const agent = await conversation.agent(context);
		const ref = agent.model;
		const model = ref === undefined ? undefined : models.getModel(ref.provider, ref.modelId);
		// Without a provider session nothing was cached under it: the follow-up would only cost more than durable's.
		const provider = await harness.snapshot(ProviderDoc, id, context);
		if (ref === undefined || model === undefined || provider === undefined) return undefined;
		const view = await conversation.context(context);
		const messages = answered(view.messages);
		const kept = describeKept(view, firstKept);
		if (messages.length === 0 || kept === undefined) return undefined;

		const prompt: Message = { role: "user", content: [{ type: "text", text: followUpPrompt(kept, instructions) }], timestamp: this.#now() };
		// The generation's own options (harness/generation.ts, `request`), so the request reads what its steps wrote.
		const options: SimpleStreamOptions = {
			...this.#stream(),
			sessionId: provider.sessionId,
			...(context.abortSignal === undefined ? {} : { signal: context.abortSignal }),
			...(agent.thinkingLevel === "off" ? {} : { reasoning: agent.thinkingLevel }),
		};
		for (let attempt = 1; ; attempt++) {
			let message: AssistantMessage;
			try {
				// Completed, not streamed: the cache warmer (src/cache.ts) sees streamed requests only, as conversation steps.
				message = await models.completeSimple(model, { messages: [...messages, prompt] }, options);
			} catch (error) {
				if (context.abortSignal?.aborted) throw error;
				console.error(`[compaction] conversation ${id}: follow-up failed, durable summarizes instead:`, error);
				return undefined;
			}
			context.abortSignal?.throwIfAborted();
			await this.#record(harness, id, message, context, taskId);
			const summary = summaryText(message);
			if (summary !== undefined) return summary;
			if (attempt < MAX_ATTEMPTS && isRetryableAssistantError(message)) {
				await sleep(retryDelayMs(this.#retry(), attempt), context.abortSignal);
				continue;
			}
			console.error(`[compaction] conversation ${id}: no summary from the follow-up (${message.stopReason}${message.errorMessage === undefined ? "" : `: ${message.errorMessage}`}), durable summarizes instead`);
			return undefined;
		}
	}

	/** Into the conversation's `pi.usage`, as durable records its summarization, and to the ledger. */
	async #record(harness: Harness, id: ConversationId, message: AssistantMessage, context: Context, taskId?: number): Promise<void> {
		const key = `${message.provider}/${message.model}`;
		await harness
			.commit(async (tx) => {
				const totals = (await tx.doc(UsageDoc, id)).models;
				const total = Object.hasOwn(totals, key) ? totals[key] : undefined;
				if (total === undefined) totals[key] = JSON.parse(JSON.stringify(message.usage));
				else addUsage(total as Usage, message.usage);
				return undefined;
			}, context)
			.catch((error: unknown) => console.error(`[compaction] conversation ${id}: usage not recorded:`, error));
		for (const listener of this.#listeners) listener({ conversationId: id, time: this.#now(), model: key, usage: message.usage, ...(taskId === undefined ? {} : { taskId }) });
	}
}

/**
 * The context up to its last complete exchange: an assistant message whose tool calls have not all been answered
 * (a manual compaction during a tool round) cannot be followed by a user message, so it and what follows are left out.
 * The rest is still the start of the cached prompt.
 */
export function answered(messages: readonly Message[]): Message[] {
	const results = new Set<string>();
	for (const message of messages) if (message.role === "toolResult") results.add(message.toolCallId);
	const open = messages.findIndex(
		(message) => message.role === "assistant" && message.content.some((content) => content.type === "toolCall" && !results.has(content.id)),
	);
	return [...(open === -1 ? messages : messages.slice(0, open))];
}

/** Names the first kept entry for the prompt: "the user message starting …", or undefined when it is not in view. */
export function describeKept(view: ContextView, firstKept: EntryId): string | undefined {
	const index = view.entries.findIndex((entry) => entry.id === firstKept);
	if (index === -1) return undefined;
	const message = view.contributions[index]?.[0];
	const clip = (text: string) => {
		const line = text.trim().split("\n")[0]?.trim() ?? "";
		return line.length > 80 ? `${line.slice(0, 80)}…` : line;
	};
	if (message?.role === "user") {
		const text = typeof message.content === "string" ? message.content : message.content.flatMap((content) => (content.type === "text" ? [content.text] : [])).join("\n");
		return clip(text) === "" ? "the user's latest messages" : `the user message starting "${clip(text)}"`;
	}
	if (message?.role === "assistant") {
		const text = message.content.flatMap((content) => (content.type === "text" ? [content.text] : [])).join("\n");
		return clip(text) === "" ? "your latest steps" : `your reply starting "${clip(text)}"`;
	}
	return "the latest messages";
}

/** Durable's rule (`summaryText`): a clean stop with text and no tool call. */
function summaryText(message: AssistantMessage): string | undefined {
	if (message.stopReason !== "stop" || message.content.some((content) => content.type === "toolCall")) return undefined;
	const text = message.content
		.flatMap((content) => (content.type === "text" ? [content.text] : []))
		.join("\n")
		.trim();
	return text.length === 0 ? undefined : text;
}

/** Durable's `addUsage`, which it does not export. */
function addUsage(total: Usage, usage: Usage): void {
	total.input += usage.input;
	total.output += usage.output;
	total.cacheRead += usage.cacheRead;
	total.cacheWrite += usage.cacheWrite;
	total.totalTokens += usage.totalTokens;
	if (usage.cacheWrite1h !== undefined) total.cacheWrite1h = (total.cacheWrite1h ?? 0) + usage.cacheWrite1h;
	if (usage.reasoning !== undefined) total.reasoning = (total.reasoning ?? 0) + usage.reasoning;
	total.cost.input += usage.cost.input;
	total.cost.output += usage.cost.output;
	total.cost.cacheRead += usage.cost.cacheRead;
	total.cost.cacheWrite += usage.cost.cacheWrite;
	total.cost.total += usage.cost.total;
}

function sleep(ms: number, signal: AbortSignal | undefined): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) return reject(signal.reason);
		const timer = setTimeout(() => {
			signal?.removeEventListener("abort", abort);
			resolve();
		}, ms);
		const abort = () => {
			clearTimeout(timer);
			reject(signal?.reason);
		};
		signal?.addEventListener("abort", abort, { once: true });
	});
}
