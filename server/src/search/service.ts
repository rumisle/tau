// The search index kept current: entries are indexed as the Session commits them, and on start whatever was written
// before the index caught up (src/search/index.ts).
import type { Context } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Message } from "@earendil-works/pi-ai";
import type { ConversationId, ConversationRecord, Cursor, EntryId, EntryRecord } from "@earendil-works/pi-durable";
import { type Host, MetaDoc } from "../host.ts";
import { type IndexEntry, type IndexPart, Kind, type KindName, SearchIndex, type SearchResponse } from "./index.ts";

/** A conversation's searchable parts: what the user and the model said, and the model's reasoning; no tool calls or output. */
export function searchParts(entry: EntryRecord): IndexPart[] {
	const message = entry.model?.[0] as Message | undefined;
	if (message === undefined) return [];
	if (entry.kind === "pi.user" && message.role === "user") {
		const content = typeof message.content === "string" ? [{ type: "text" as const, text: message.content }] : message.content;
		const text = content.map((block) => (block.type === "text" ? block.text : "")).join("\n");
		// A subagent's report reads as the agent's.
		return text.trim() === "" ? [] : [{ kind: text.startsWith("<subagent ") ? Kind.assistant : Kind.user, text, idx: 0 }];
	}
	if (entry.kind === "pi.assistant" && message.role === "assistant") {
		// A failed response is retried or shown as its error; neither is what was said.
		if (message.stopReason === "error") return [];
		const parts: IndexPart[] = [];
		message.content.forEach((block, idx) => {
			if (block.type === "text" && block.text.trim() !== "") parts.push({ kind: Kind.assistant, text: block.text, idx });
			else if (block.type === "thinking" && block.thinking.trim() !== "") parts.push({ kind: Kind.reasoning, text: block.thinking, idx });
		});
		return parts;
	}
	return [];
}

/** The text of part `idx` of an entry, as `searchParts` indexed it. */
function partText(entry: EntryRecord, idx: number): string | undefined {
	const message = entry.model?.[0] as Message | undefined;
	if (message === undefined) return undefined;
	if (message.role === "user") {
		const content = typeof message.content === "string" ? [{ type: "text" as const, text: message.content }] : message.content;
		return content.map((block) => (block.type === "text" ? block.text : "")).join("\n");
	}
	if (message.role === "assistant") {
		const block = message.content[idx];
		if (block?.type === "text") return block.text;
		if (block?.type === "thinking") return block.thinking;
	}
	return undefined;
}

function indexEntry(entry: EntryRecord): IndexEntry | undefined {
	const parts = searchParts(entry);
	if (parts.length === 0) return undefined;
	const timestamp = (entry.model?.[0] as { timestamp?: number } | undefined)?.timestamp;
	return { conversationId: entry.conversationId, entryId: entry.id, time: timestamp ?? Date.now(), parts };
}

export class Search {
	readonly index: SearchIndex;
	readonly #host: Host;
	readonly #unsubscribe: () => void;
	/** Entries committed while the backfill runs, indexed after it. */
	#pending: IndexEntry[] = [];
	#flushScheduled = false;
	#backfilling = true;
	readonly ready: Promise<void>;

	/** `path`: the index file; ":memory:" for one that lives as long as the process. */
	constructor(host: Host, path: string) {
		this.#host = host;
		this.index = new SearchIndex(path);
		this.#unsubscribe = host.harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type === "entry") {
					const entry = indexEntry(change.value);
					if (entry !== undefined) this.#pending.push(entry);
				} else if (change.type === "conversation") {
					this.#conversation(change.value);
				} else if (change.type === "document" && change.conversationId !== undefined && change.record.kind === MetaDoc.definition.kind) {
					const meta = change.value as { title?: string; archived?: boolean } | null;
					this.#meta(change.conversationId, meta ?? {});
				}
			}
			this.#scheduleFlush();
		});
		this.ready = this.#backfill().catch((error) => console.error("[search] backfill failed:", error));
	}

	close(): void {
		this.#unsubscribe();
		this.index.close();
	}

	#conversation(record: ConversationRecord): void {
		this.index.setConversation(record.id, record.parent === undefined ? {} : { parent: { conversationId: record.parent.conversationId, at: record.parent.at } });
	}

	#titles = new Map<number, string>();
	#archived = new Map<number, boolean>();

	#meta(conversationId: number, meta: { title?: string; archived?: boolean }): void {
		const title = meta.title ?? "";
		if (this.#titles.get(conversationId) !== title) {
			this.#titles.set(conversationId, title);
			this.index.setTitle(conversationId, title);
		}
		const archived = meta.archived === true;
		if (this.#archived.get(conversationId) !== archived) {
			this.#archived.set(conversationId, archived);
			this.index.setArchived(conversationId, archived);
		}
	}

	#scheduleFlush(): void {
		if (this.#flushScheduled || this.#backfilling || this.#pending.length === 0) return;
		this.#flushScheduled = true;
		setImmediate(() => {
			this.#flushScheduled = false;
			const pending = this.#pending;
			this.#pending = [];
			try {
				this.index.add(pending);
			} catch (error) {
				console.error("[search] indexing failed:", error);
			}
		});
	}

	/** Every conversation's entries past what the index has, oldest first, a page at a time. */
	async #backfill(): Promise<void> {
		const { storage, harness } = this.#host;
		const context = BACKGROUND_CONTEXT;
		const started = performance.now();
		let indexed = 0;
		let cursor: Cursor | undefined;
		do {
			const page = await storage.scanConversations({}, 200, cursor, context);
			for (const conversation of page.items) {
				this.#conversation(conversation);
				const meta = await harness.snapshot(MetaDoc, conversation.id, context);
				this.#meta(conversation.id, meta ?? {});
				let entries: Cursor | undefined;
				const after = this.index.cursor(conversation.id);
				do {
					const batch = await storage.scanEntries({ conversationId: conversation.id, minEntryId: (after + 1) as EntryId, order: "ascending" }, 256, entries, context);
					// A fork sees its origin's entries too; each is indexed once, as its own conversation's.
					const own = batch.items.filter((entry) => entry.conversationId === conversation.id).flatMap((entry) => indexEntry(entry) ?? []);
					this.index.add(own);
					indexed += own.length;
					entries = batch.next;
					// Let requests in between pages.
					await new Promise((resolve) => setImmediate(resolve));
				} while (entries !== undefined);
			}
			cursor = page.next;
		} while (cursor !== undefined);
		this.#backfilling = false;
		this.#scheduleFlush();
		if (indexed > 0) console.log(`[search] indexed ${indexed} entries in ${((performance.now() - started) / 1000).toFixed(1)} s`);
	}

	/** Conversations matching `query`, best first, with an excerpt of their best match. */
	async search(query: string, options: { limit?: number; offset?: number; kinds?: KindName[]; typing?: boolean }, context: Context): Promise<SearchResponse> {
		await this.ready;
		const { storage } = this.#host;
		const load = async (conversationId: number, entryId: number, idx: number): Promise<string | undefined> => {
			if (idx < 0) return this.#titles.get(conversationId);
			const found = await storage.entry(conversationId as ConversationId, entryId as EntryId, context);
			return found === undefined ? undefined : partText(found.entry, idx);
		};
		return this.index.search(query, load, { ...options, hits: 1 });
	}

	/** One conversation's matching entries, newest first. */
	async searchConversation(conversationId: number, query: string, options: { kinds?: KindName[]; typing?: boolean }): Promise<ReturnType<SearchIndex["searchConversation"]>> {
		await this.ready;
		return this.index.searchConversation(conversationId, query, options);
	}
}
