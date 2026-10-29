// Each conversation's compactions from start to end, for the app's card (docs/compaction.md, "In the app"): durable
// shows one only while its task runs (`pi.live.compactions`) and leaves its summary as an entry, placed at once, at the
// next boundary of a run that goes on meanwhile, or never (settled `stale` when the conversation moved past it). tau
// keeps what became of each in `tau.compactions`, with the context's size before and after and what the summary cost,
// so a chat can say it from the moment it starts to after it is placed or was not used, and still say it later.
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { type ConversationId, defineDoc, type EntryRecord, type Harness, LiveDoc } from "@earendil-works/pi-durable";
import type { FollowUpCompaction } from "./compaction.ts";

export type CompactionRecord = {
	taskId: number;
	reason: string;
	/** A run waits for it (past durable's blocking threshold, or an overflow). */
	blocking: boolean;
	startedAt: number;
	/**
	 * `running` while its task works; `waiting` with its summary admitted, for a run's next boundary; `placed` once the
	 * summary is in the transcript (`entryId`); `stale` when the conversation moved past it and it was not used;
	 * `failed` with `error`; `empty` when there was nothing to compact.
	 */
	state: "running" | "waiting" | "placed" | "stale" | "failed" | "empty";
	endedAt?: number;
	entryId?: number;
	/** Not used (stale, failed, empty): the newest entry then, where the chat says so. */
	after?: number;
	error?: string;
	/** The context the last answer before it read and wrote, and the one the first answer after its summary read. */
	tokensBefore?: number;
	tokensAfter?: number;
	/** What tau's summary request cost (durable's own summarization, the fallback, is not counted here). */
	cost?: number;
};

export const CompactionsDoc = defineDoc<{ items: CompactionRecord[] }>({
	kind: "tau.compactions",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({ items: [] }),
});

/** The newest this many a conversation keeps. */
const KEPT = 50;

type LiveCompactions = { compactions?: { taskId: number; reason: string; blocking: boolean }[]; compactionFailure?: { taskId: number; error: string } } | null;

/** What one commit said of one conversation's compactions. */
type Seen = {
	live?: LiveCompactions;
	entries: EntryRecord[];
	submissions: { taskId: number; status: string; entry?: number; reason?: string }[];
};

export class CompactionLog {
	readonly #harness: Harness;
	/** Each conversation's compaction tasks and failure as last seen in `pi.live`: it changes on every token. */
	readonly #lastLive = new Map<ConversationId, string>();
	readonly #writes = new Map<ConversationId, Promise<void>>();
	readonly #unsubscribe: () => void;
	readonly #unsubscribeUsage: () => void;
	readonly #listeners = new Set<(id: ConversationId, items: CompactionRecord[]) => void>();
	#closed = false;

	constructor(harness: Harness, followUp: FollowUpCompaction) {
		this.#harness = harness;
		this.#unsubscribe = harness.subscribeCommits((publication) => {
			const seen = new Map<ConversationId, Seen>();
			const of = (id: ConversationId) => {
				let each = seen.get(id);
				if (each === undefined) {
					each = { entries: [], submissions: [] };
					seen.set(id, each);
				}
				return each;
			};
			for (const change of publication.changes) {
				if (change.type === "entry" && (change.value.kind === "pi.compaction" || change.value.kind === "pi.assistant")) {
					of(change.value.conversationId).entries.push(change.value);
				} else if (change.type === "submission") {
					const record = change.value as { conversationId: ConversationId; requestId?: string; status: string; entry?: number; reason?: string };
					const match = /^compaction:(\d+)$/.exec(record.requestId ?? "");
					if (match !== null) of(record.conversationId).submissions.push({ taskId: Number(match[1]), status: record.status, entry: record.entry, reason: record.reason });
				} else if (change.type === "document" && change.conversationId !== undefined && change.record.kind === LiveDoc.definition.kind) {
					const live = change.value as LiveCompactions;
					const key = JSON.stringify([live?.compactions?.map((each) => each.taskId) ?? [], live?.compactionFailure?.taskId ?? null]);
					if (this.#lastLive.get(change.conversationId) === key) continue;
					this.#lastLive.set(change.conversationId, key);
					of(change.conversationId).live = live;
				}
			}
			for (const [id, each] of seen) {
				// Assistant entries alone matter only to a summary waiting for the size after it.
				if (each.live === undefined && each.submissions.length === 0 && !each.entries.some((entry) => entry.kind === "pi.compaction")) {
					if (!each.entries.some((entry) => entry.kind === "pi.assistant") || !this.#measuring.has(id)) continue;
				}
				// After the commit: listeners must not commit.
				this.#write(id, (items) => this.#apply(id, items, each));
			}
		});
		this.#unsubscribeUsage = followUp.onUsage((record) => {
			this.#write(record.conversationId, (items) => {
				const running = items.findLast((item) => item.state === "running");
				if (running !== undefined) running.cost = (running.cost ?? 0) + record.usage.cost.total;
			});
		});
	}

	/** A conversation's records changed, after the commit: all of them. */
	onChange(listener: (id: ConversationId, items: CompactionRecord[]) => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	/** A conversation's records as kept. */
	async records(id: ConversationId): Promise<CompactionRecord[]> {
		return [...((await this.#harness.snapshot(CompactionsDoc, id, BACKGROUND_CONTEXT))?.items ?? [])];
	}

	close(): void {
		this.#closed = true;
		this.#unsubscribe();
		this.#unsubscribeUsage();
	}

	/** Conversations with a placed summary still to measure the next answer's context for. */
	readonly #measuring = new Set<ConversationId>();

	async #apply(id: ConversationId, items: CompactionRecord[], seen: Seen): Promise<void> {
		const now = Date.now();
		const find = (taskId: number) => items.find((item) => item.taskId === taskId);
		// Started.
		for (const status of seen.live?.compactions ?? []) {
			if (find(status.taskId) !== undefined) continue;
			items.push({ taskId: status.taskId, reason: status.reason, blocking: status.blocking, startedAt: now, state: "running", tokensBefore: await this.#contextBefore(id) });
		}
		// Placed: a blocking one's entry is its task's own; a conversation's comes through its write submission.
		for (const entry of seen.entries) {
			if (entry.kind !== "pi.compaction" || entry.byTaskId === undefined) continue;
			const item = find(entry.byTaskId);
			if (item !== undefined) await this.#placed(id, item, entry.id, now);
		}
		for (const submission of seen.submissions) {
			const item = find(submission.taskId);
			if (item === undefined) continue;
			if ((submission.status === "placed" || submission.status === "done") && submission.entry !== undefined) {
				await this.#placed(id, item, submission.entry, now);
			} else if (submission.status === "queued" && item.state === "running") {
				item.state = "waiting";
			} else if (submission.status === "unanswered" && item.state !== "placed") {
				item.state = submission.reason === "stale" ? "stale" : "failed";
				if (submission.reason !== "stale") item.error = submission.reason;
				item.endedAt = now;
				item.after = await this.#newestEntry(id);
			}
		}
		// Ended without a summary: failed, or nothing to compact.
		if (seen.live !== undefined) {
			const running = new Set(seen.live?.compactions?.map((each) => each.taskId) ?? []);
			for (const item of items) {
				if (item.state !== "running" || running.has(item.taskId)) continue;
				const failure = seen.live?.compactionFailure;
				item.state = failure?.taskId === item.taskId ? "failed" : "empty";
				if (failure?.taskId === item.taskId) item.error = failure.error;
				item.endedAt = now;
				item.after = await this.#newestEntry(id);
			}
		}
		// The size after: what the first answer after the summary read.
		for (const entry of seen.entries) {
			if (entry.kind !== "pi.assistant") continue;
			const message = entry.model?.[0] as AssistantMessage | undefined;
			if (message === undefined || message.stopReason === "error" || message.stopReason === "aborted") continue;
			for (const item of items) {
				if (item.state === "placed" && item.tokensAfter === undefined && item.entryId !== undefined && item.entryId < entry.id) item.tokensAfter = read(message);
			}
		}
		if (items.some((item) => item.state === "placed" && item.tokensAfter === undefined)) this.#measuring.add(id);
		else this.#measuring.delete(id);
		if (items.length > KEPT) items.splice(0, items.length - KEPT);
	}

	async #placed(id: ConversationId, item: CompactionRecord, entryId: number, now: number): Promise<void> {
		if (item.state === "placed") return;
		item.state = "placed";
		item.entryId = entryId;
		item.endedAt = now;
		// The size before: at the last answer before the summary, which a compaction started mid-run may follow.
		item.tokensBefore = (await this.#contextBefore(id, entryId)) ?? item.tokensBefore;
	}

	/**
	 * The context at the end of the last answer (before `entryId`): what it read, and what it wrote, which the next
	 * request reads.
	 */
	async #contextBefore(id: ConversationId, entryId?: number): Promise<number | undefined> {
		const conversation = await this.#harness.conversation(id, BACKGROUND_CONTEXT);
		const page = await conversation?.entries(entryId === undefined ? {} : { maxEntryId: (entryId - 1) as never }, 64, undefined, BACKGROUND_CONTEXT);
		for (const entry of page?.items ?? []) {
			if (entry.kind !== "pi.assistant") continue;
			const message = entry.model?.[0] as AssistantMessage | undefined;
			if (message === undefined || message.stopReason === "error" || message.stopReason === "aborted") continue;
			return read(message) + message.usage.output;
		}
		return undefined;
	}

	async #newestEntry(id: ConversationId): Promise<number | undefined> {
		const conversation = await this.#harness.conversation(id, BACKGROUND_CONTEXT);
		const page = await conversation?.entries({}, 1, undefined, BACKGROUND_CONTEXT);
		return page?.items[0]?.id;
	}

	#write(id: ConversationId, update: (items: CompactionRecord[]) => void | Promise<void>): void {
		if (this.#closed) return;
		const next = (this.#writes.get(id) ?? Promise.resolve())
			.then(() => new Promise((resolve) => setTimeout(resolve, 0)))
			.then(async () => {
				if (this.#closed) return;
				// Worked out before the commit, which must not wait on reads of its own.
				const doc = (await this.#harness.snapshot(CompactionsDoc, id, BACKGROUND_CONTEXT)) ?? { items: [] };
				const items: CompactionRecord[] = JSON.parse(JSON.stringify(doc.items ?? []));
				const before = JSON.stringify(items);
				await update(items);
				if (JSON.stringify(items) === before) return;
				await this.#harness.commit(async (tx) => {
					(await tx.doc(CompactionsDoc, id)).items = items;
					return undefined;
				}, BACKGROUND_CONTEXT);
				for (const listener of this.#listeners) listener(id, items);
			})
			.catch((error: unknown) => console.error(`[compaction] conversation ${id}: record not kept:`, error))
			.finally(() => {
				if (this.#writes.get(id) === next) this.#writes.delete(id);
			});
		this.#writes.set(id, next);
	}

	/** Until the writes queued so far are done (tests). */
	async settled(): Promise<void> {
		await Promise.all([...this.#writes.values()]);
	}
}

/** The context a request read: new, from the cache, and written to it. */
function read(message: AssistantMessage): number {
	return message.usage.input + message.usage.cacheRead + message.usage.cacheWrite;
}
