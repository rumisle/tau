// Prompt cache warming, after pi's coding agent (packages/coding-agent/src/core/cache-warmer.ts). A provider keeps the
// prompt of a request cached for a while (Anthropic: five minutes); the next request that starts with it reads it at a
// tenth of the price instead of writing it again at more than the full one. A run that waits longer than that, on a
// long tool call, would lose it: so while a run works, its last request is sent again with a one-token cap shortly
// before the entry expires, when that is expected to save more than it costs. An idle chat lets its cache go, as pi's
// default "streaming" mode does: whether the user writes again in time is a guess, and seldom worth the refresh.
//
// The harness reaches models only through `HarnessOptions.models`; `wrap()` gives it one whose `streamSimple` sees
// every request as it is sent. The generation hook `beforeRequest` tells which conversation a provider session ID is.
// What a conversation's cache did is kept in `tau.cache`, and its chat list Dialog shows it (docs/cache.md).
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
	type Api,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type Context as ModelContext,
	calculateCost,
	type Model,
	type Models,
	type ModelsSimpleStreamOptions,
	type Usage,
} from "@earendil-works/pi-ai";
import {
	AgentDoc,
	type ConversationId,
	defineDoc,
	GenerationTask,
	type Harness,
	type HookRegistration,
	hook,
	LiveDoc,
	ProviderDoc,
} from "@earendil-works/pi-durable";

/** A refresh is sent only when it is expected to save at least this much, in dollars (pi's threshold). */
const MINIMUM_SAVINGS = 0.05;
/** Warming never goes on longer than this after the real request it keeps, as pi's safety limit. */
const MAX_WARMING_MS = 60 * 60_000;

/** What a conversation's prompt cache did; the counters are its whole life. */
export type CacheState = {
	/** How long the model keeps a cache entry, in milliseconds. */
	ttl?: number;
	/** When the entry was last written or read: the start of that request. It expires `ttl` after. */
	at?: number;
	/** Refreshes sent, what they cost, and what they saved: what the requests they kept warm would have paid more. */
	warms?: number;
	cost?: number;
	saved?: number;
};
export const CacheDoc = defineDoc<CacheState>({
	kind: "tau.cache",
	version: 1,
	scope: "conversation",
	history: "latest",
	// A fork is another provider session: its cache is its own.
	fork: "initial",
	initial: () => ({}),
});

/** One refresh, for the usage ledger. */
export type WarmRecord = { conversationId: ConversationId; time: number; model: string; usage: Usage };

/** Refresh at 90% of the lifetime, keeping at least ten seconds of margin (pi's `getCacheWarmingDelayMs`). */
export function warmDelay(ttl: number): number | undefined {
	if (ttl <= 10_000) return undefined;
	return Math.max(1, Math.floor(Math.min(ttl * 0.9, ttl - 10_000)));
}

/** The lifetime of the entry a request writes, from the model's `promptCache`; undefined when it declares none. */
export function promptCacheTtl(model: Model<Api>, options: ModelsSimpleStreamOptions | undefined): number | undefined {
	const retention = options?.cacheRetention ?? (process.env.PI_CACHE_RETENTION === "long" ? "long" : "short");
	if (retention === "none") return undefined;
	const seconds = model.promptCache?.[retention];
	return seconds === undefined ? undefined : seconds * 1000;
}

/**
 * Whether the request sent again with a one-token cap reads the same entry. Anthropic's budget thinking (Claude models
 * without adaptive thinking) takes its budget from `max_tokens`, and keys the cache on it (pi's `isReplayable`).
 */
export function replayable(model: Model<Api>, options: ModelsSimpleStreamOptions | undefined): boolean {
	if (options?.reasoning === undefined || model.api !== "anthropic-messages") return true;
	return (model as Model<"anthropic-messages">).compat?.forceAdaptiveThinking === true;
}

function price(model: Model<Api>, tokens: Partial<Pick<Usage, "input" | "output" | "cacheRead" | "cacheWrite">>): number {
	const usage: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }, ...tokens };
	return calculateCost(model, usage).total;
}

/** What a prompt of `tokens` costs to read from the cache, and how much more to write it into a cold one. */
function economics(model: Model<Api>, tokens: number): { warmCost: number; missCost: number } {
	const hit = price(model, { cacheRead: tokens });
	const miss = price(model, model.cost.cacheWrite > 0 ? { cacheWrite: tokens } : { input: tokens });
	return { warmCost: price(model, { cacheRead: tokens, output: 1 }), missCost: Math.max(0, miss - hit) };
}

/** The request a conversation's run sent last, kept warm until the run ends or another request replaces it. */
type Run = {
	model: Model<Api>;
	context: ModelContext;
	options: ModelsSimpleStreamOptions;
	ttl: number;
	delay: number;
	startedAt: number;
	controller: AbortController;
	timer?: ReturnType<typeof setTimeout>;
	/** Latest time a refresh may go: later, the entry may be gone and it would write, not read. */
	deadline: number;
};

/** A conversation's cache entry as its requests left it. */
type Entry = {
	/** When it was last written or read, by a request or a refresh. */
	at: number;
	/** The start of the last real request that read or wrote it. */
	real: number;
	ttl: number;
	promptTokens: number;
	/** Refreshes since that request. */
	warms: number;
};

export class CacheWarmer {
	#harness?: Harness;
	/** The models refreshes go through: the unwrapped ones, so a refresh is not taken for a request. */
	#models?: Models;
	readonly #runs = new Map<ConversationId, Run>();
	readonly #entries = new Map<ConversationId, Entry>();
	/** Provider session ID to conversation, from `beforeRequest`. */
	readonly #sessions = new Map<string, ConversationId>();
	readonly #changeListeners = new Set<(id: ConversationId) => void>();
	readonly #warmListeners = new Set<(record: WarmRecord) => void>();
	/** Commits of `tau.cache`, in order per conversation. */
	readonly #writes = new Map<ConversationId, Promise<void>>();
	#unsubscribe?: () => void;
	#closed = false;
	readonly #now: () => number;

	constructor(options: { now?: () => number } = {}) {
		this.#now = options.now ?? Date.now;
	}

	/** Learns which conversation each request is for. */
	readonly hook: HookRegistration = hook(GenerationTask, {
		beforeRequest: async (_request, api, context) => {
			const provider = await api.snapshot(ProviderDoc, api.conversationId, context);
			if (provider !== undefined) this.#sessions.set(provider.sessionId, api.conversationId);
			return undefined;
		},
	});

	/** `models` as the harness should get them: the same, but each conversation request is seen. */
	wrap(models: Models): Models {
		this.#models = models;
		return new Proxy(models, {
			get: (target, property) => {
				if (property === "streamSimple") {
					return (model: Model<Api>, context: ModelContext, options?: ModelsSimpleStreamOptions) => {
						const events = target.streamSimple(model, context, options);
						this.#sent(model, context, options, events);
						return events;
					};
				}
				const value = Reflect.get(target, property, target);
				return typeof value === "function" ? value.bind(target) : value;
			},
		});
	}

	/** After the harness opens: runs that end stop warming. */
	attach(harness: Harness): void {
		this.#harness = harness;
		this.#unsubscribe = harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type === "document" && change.conversationId !== undefined && change.record.kind === LiveDoc.definition.kind) {
					const live = change.value as { run?: unknown } | null;
					if (live?.run === undefined) this.#stop(change.conversationId);
				} else if (change.type === "entry" && (change.value.kind === "pi.compaction" || change.value.kind === "pi.reset")) {
					// The next request starts with another prompt.
					this.#stop(change.value.conversationId);
				}
			}
		});
	}

	close(): void {
		this.#closed = true;
		this.#unsubscribe?.();
		for (const id of [...this.#runs.keys()]) this.#stop(id);
	}

	/** Whether a refresh is scheduled for the conversation now. */
	isWarming(id: ConversationId): boolean {
		return this.#runs.has(id);
	}

	/** A conversation whose warming started or stopped. */
	onChange(listener: (id: ConversationId) => void): () => void {
		this.#changeListeners.add(listener);
		return () => this.#changeListeners.delete(listener);
	}

	/** Each refresh that went through. */
	onWarm(listener: (record: WarmRecord) => void): () => void {
		this.#warmListeners.add(listener);
		return () => this.#warmListeners.delete(listener);
	}

	#sent(model: Model<Api>, context: ModelContext, options: ModelsSimpleStreamOptions | undefined, events: AssistantMessageEventStream): void {
		// The conversation's own requests only: compaction completes instead of streaming, titles have no session.
		const id = options?.sessionId === undefined ? undefined : this.#sessions.get(options.sessionId);
		if (id === undefined || options === undefined || this.#closed) return;
		const ttl = promptCacheTtl(model, options);
		if (ttl === undefined) return;
		const startedAt = this.#now();
		this.#start(id, model, context, options, ttl, startedAt);
		void events.result().then(
			(message) => this.#answered(id, model, message, ttl, startedAt),
			() => undefined,
		);
	}

	#start(id: ConversationId, model: Model<Api>, context: ModelContext, options: ModelsSimpleStreamOptions, ttl: number, startedAt: number): void {
		const had = this.#runs.has(id);
		this.#clear(id);
		const delay = warmDelay(ttl);
		if (delay === undefined || !replayable(model, options)) {
			if (had) this.#changed(id);
			return;
		}
		// The request's own signal ends with its attempt; a refresh has its own.
		const { signal: _signal, ...rest } = options;
		const run: Run = { model, context, options: rest, ttl, delay, startedAt, controller: new AbortController(), deadline: 0 };
		this.#runs.set(id, run);
		this.#schedule(id, run, startedAt);
		if (!had && this.#runs.get(id) === run) this.#changed(id);
	}

	#schedule(id: ConversationId, run: Run, from: number): void {
		const next = from + run.delay;
		if (next > run.startedAt + MAX_WARMING_MS) {
			this.#stop(id);
			return;
		}
		// A timer late after sleep or a blocked loop keeps half of the margin; later, a refresh would rewrite the entry.
		run.deadline = next + Math.floor((run.ttl - run.delay) / 2);
		run.timer = setTimeout(() => void this.#refresh(id, run), Math.max(0, next - this.#now()));
		run.timer.unref?.();
	}

	async #refresh(id: ConversationId, run: Run): Promise<void> {
		run.timer = undefined;
		if (this.#runs.get(id) !== run) return;
		const now = this.#now();
		const entry = this.#entries.get(id);
		const models = this.#models;
		if (now > run.deadline || entry === undefined || models === undefined || !(await this.#current(id, run))) {
			this.#stop(id);
			return;
		}
		// While the run works its next request is certain: a refresh pays when a miss costs more than the read.
		const { warmCost, missCost } = economics(run.model, entry.promptTokens);
		if (missCost - warmCost < MINIMUM_SAVINGS) {
			this.#stop(id);
			return;
		}
		try {
			const message = await models.streamSimple(run.model, run.context, { ...run.options, maxTokens: 1, maxRetries: 0, signal: run.controller.signal }).result();
			if (this.#runs.get(id) === run && message.stopReason !== "error" && message.stopReason !== "aborted") {
				const usage = message.usage;
				if (usage.cacheRead > 0 && this.#entries.get(id) === entry) {
					entry.at = now;
					entry.warms += 1;
				}
				this.#write(id, (state) => {
					state.ttl = run.ttl;
					if (usage.cacheRead > 0) state.at = Math.max(state.at ?? 0, now);
					state.warms = (state.warms ?? 0) + 1;
					state.cost = (state.cost ?? 0) + usage.cost.total;
				});
				const record = { conversationId: id, time: now, model: `${message.provider}/${message.model}`, usage };
				for (const listener of this.#warmListeners) listener(record);
			}
		} catch {
			// Best effort: a refresh that fails changes nothing for the run.
		}
		if (this.#runs.get(id) === run) this.#schedule(id, run, now);
	}

	/** A real request's answer: when the entry was written or read, how big the prompt is, and what refreshes saved. */
	#answered(id: ConversationId, model: Model<Api>, message: AssistantMessage, ttl: number, startedAt: number): void {
		if (message.stopReason === "error" || message.stopReason === "aborted") return;
		const usage = message.usage;
		if (usage.cacheRead + usage.cacheWrite === 0) return;
		const previous = this.#entries.get(id);
		// What it read from an entry only refreshes kept alive would otherwise have been written again.
		const bridged = previous !== undefined && previous.warms > 0 && startedAt - previous.real > previous.ttl && startedAt - previous.at <= previous.ttl;
		const saved = bridged && usage.cacheRead > 0 ? Math.max(0, price(model, { cacheWrite: usage.cacheRead }) - price(model, { cacheRead: usage.cacheRead })) : 0;
		this.#entries.set(id, { at: startedAt, real: startedAt, ttl, promptTokens: usage.input + usage.cacheRead + usage.cacheWrite, warms: 0 });
		this.#write(id, (state) => {
			state.ttl = ttl;
			state.at = Math.max(state.at ?? 0, startedAt);
			if (saved > 0) state.saved = (state.saved ?? 0) + saved;
		});
	}

	/** Whether the conversation still asks the model the request was for. */
	async #current(id: ConversationId, run: Run): Promise<boolean> {
		const agent = await this.#harness?.snapshot(AgentDoc, id, BACKGROUND_CONTEXT).catch(() => undefined);
		const model = agent?.model;
		return model === undefined || (model.provider === run.model.provider && model.modelId === run.model.id);
	}

	#clear(id: ConversationId): void {
		const run = this.#runs.get(id);
		if (run === undefined) return;
		this.#runs.delete(id);
		if (run.timer !== undefined) clearTimeout(run.timer);
		run.controller.abort();
	}

	#stop(id: ConversationId): void {
		if (!this.#runs.has(id)) return;
		this.#clear(id);
		this.#changed(id);
	}

	#changed(id: ConversationId): void {
		for (const listener of this.#changeListeners) listener(id);
	}

	#write(id: ConversationId, update: (state: CacheState) => void): void {
		const harness = this.#harness;
		if (harness === undefined || this.#closed) return;
		const next = (this.#writes.get(id) ?? Promise.resolve())
			.then(() =>
				harness.commit(async (tx) => {
					update(await tx.doc(CacheDoc, id));
					return undefined;
				}, BACKGROUND_CONTEXT),
			)
			.catch(() => undefined)
			.finally(() => {
				if (this.#writes.get(id) === next) this.#writes.delete(id);
			});
		this.#writes.set(id, next);
	}
}
