// A conversation's replica (docs/protocol.md "Sync model"): cached entries by ID, known holes, docs kept current with
// ops, the active context's head. It survives reconnects: `sync()` on a new connection fetches only what is missing.
import type { TauClient } from "./connection.ts";
import { applyOps } from "./ops.ts";
import type { Entry, HistoryResult, JsonObject, Op, Push, SubscribeResult } from "./protocol.ts";

/**
 * Client-side state of one conversation: cached entries by ID, known holes, docs, and the active context head.
 * Survives reconnects: `sync()` on a new connection fetches only what is missing.
 */
export class ConversationReplica {
	readonly id: number;
	readonly entries = new Map<number, Entry>();
	/** ID ranges (exclusive bounds) known to be missing from `entries`. */
	readonly holes: { after: number; before: number }[] = [];
	docs: JsonObject = {};
	head: number | undefined;
	hasOlder = false;
	submissions = new Map<number, JsonObject>();
	#stop: (() => void) | undefined;
	readonly #changed = new Set<() => void>();

	constructor(id: number) {
		this.id = id;
	}

	get maxId(): number {
		let max = 0;
		for (const id of this.entries.keys()) max = Math.max(max, id);
		return max;
	}

	/** Entries in transcript order. */
	ordered(): Entry[] {
		return [...this.entries.values()].sort((a, b) => a.id - b.id);
	}

	/** Subscribe on `client`, fetching only entries newer than the cache. */
	async sync(client: TauClient, options: { limit?: number } = {}): Promise<void> {
		this.#stop?.();
		const buffered: Push[] = [];
		let ready = false;
		this.#stop = client.on((push) => {
			if (push.conversationId !== this.id && (push.record as JsonObject | undefined)?.conversationId !== this.id) return;
			if (ready) this.#apply(push);
			else buffered.push(push);
		});
		const after = this.entries.size === 0 ? undefined : this.maxId;
		const result = await client.request<SubscribeResult>("conversation.subscribe", {
			conversationId: this.id,
			...(after === undefined ? {} : { after }),
			...(options.limit === undefined ? {} : { limit: options.limit }),
		});
		this.docs = result.docs;
		this.head = result.head;
		if (after === undefined) this.hasOlder = result.hasOlder;
		if (result.gap !== undefined) this.holes.push(result.gap);
		this.#upsert(result.entries);
		for (const record of result.submissions as JsonObject[]) this.submissions.set(record.id as number, record);
		ready = true;
		for (const push of buffered) this.#apply(push);
		this.#emit();
	}

	/** Load up to `limit` entries before the oldest cached one. */
	async loadOlder(client: TauClient, limit = 50): Promise<void> {
		const oldest = Math.min(...this.entries.keys());
		const result = await client.request<HistoryResult>("conversation.history", { conversationId: this.id, before: oldest, limit });
		this.#upsert(result.entries);
		this.hasOlder = result.hasOlder;
		this.#emit();
	}

	/** Fill the newest hole, one page at a time. */
	async fillHole(client: TauClient, limit = 50): Promise<void> {
		const hole = this.holes.at(-1);
		if (hole === undefined) return;
		const result = await client.request<HistoryResult>("conversation.history", {
			conversationId: this.id,
			before: hole.before,
			after: hole.after,
			limit,
		});
		this.#upsert(result.entries);
		const first = (result.entries as Entry[])[0];
		if (!result.hasOlder || first === undefined) this.holes.pop();
		else hole.before = first.id;
		this.#emit();
	}

	detach(): void {
		this.#stop?.();
		this.#stop = undefined;
	}

	onChange(listener: () => void): () => void {
		this.#changed.add(listener);
		return () => this.#changed.delete(listener);
	}

	#apply(push: Push): void {
		switch (push.event) {
			case "conv.commit":
				if (push.docs !== undefined) this.docs = push.docs as JsonObject;
				if (push.ops !== undefined) this.docs = applyOps(this.docs, push.ops as Op[]) as JsonObject;
				if (push.entries !== undefined) this.#upsert(push.entries as Entry[]);
				if (push.head !== undefined) this.head = push.head as number;
				break;
			case "submission": {
				const record = push.record as JsonObject;
				this.submissions.set(record.id as number, record);
				break;
			}
			default:
				return;
		}
		this.#emit();
	}

	#upsert(entries: Entry[]): void {
		for (const entry of entries) this.entries.set(entry.id, entry);
	}

	#emit(): void {
		for (const listener of this.#changed) listener();
	}
}
