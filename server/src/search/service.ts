// The search index kept current: entries are indexed as the Session commits them, and on start whatever was written
// before the index caught up (src/search/index.ts).
import type { Context } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Message } from "@earendil-works/pi-ai";
import type { ConversationId, ConversationRecord, Cursor, EntryId, EntryRecord } from "@earendil-works/pi-durable";
import { attachedFiles, fileIdFromPath, ownText } from "../attachments.ts";
import { FilesEntry } from "../shown.ts";
import { type Host, MetaDoc } from "../host.ts";
import { type IndexEntry, type IndexPart, Kind, type KindName, SearchIndex, type SearchResponse } from "./index.ts";
import { type UsageReport, UsageLedger, type UsageRow } from "./usage.ts";
import { type IndexWriter, localWriter, WorkerWriter } from "./writer.ts";
import { onCommit, changedValue } from "../commits.ts";

/** A conversation's searchable parts: what the user and the model said, and the model's reasoning; no tool calls or output. */
export function searchParts(entry: EntryRecord): IndexPart[] {
	const message = entry.model?.[0] as Message | undefined;
	if (message === undefined) return [];
	if (entry.kind === "pi.user" && message.role === "user") {
		const text = userSearchText(message.content);
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

/** A user message as search finds it: what it says, then its files' names, without the attachments block's paths. */
function userSearchText(content: Extract<Message, { role: "user" }>["content"]): string {
	const names = attachedFiles(content).map((file) => file.path.split("/").at(-1) ?? "");
	return [ownText(content), ...names].filter((part) => part !== "").join("\n");
}

/** The text of part `idx` of an entry, as `searchParts` indexed it. */
function partText(entry: EntryRecord, idx: number): string | undefined {
	const message = entry.model?.[0] as Message | undefined;
	if (message === undefined) return undefined;
	if (message.role === "user") return userSearchText(message.content);
	if (message.role === "assistant") {
		const block = message.content[idx];
		if (block?.type === "text") return block.text;
		if (block?.type === "thinking") return block.thinking;
	}
	return undefined;
}

/** Every entry moves its conversation's cursor; those with something to search add parts. */
function indexEntry(entry: EntryRecord): IndexEntry {
	const timestamp = (entry.model?.[0] as { timestamp?: number } | undefined)?.timestamp;
	const files = entryFiles(entry);
	return { conversationId: entry.conversationId, entryId: entry.id, time: timestamp ?? Date.now(), parts: searchParts(entry), ...(files.length === 0 ? {} : { files }) };
}

/** The kept files an entry names: a user message's attachments, what send_file sent (from a script, its entry's). */
function entryFiles(entry: EntryRecord): string[] {
	if (FilesEntry.is(entry)) return entry.data.files.map((file) => file.id);
	const message = entry.model?.[0] as Message | undefined;
	if (message?.role === "user") return attachedFiles(message.content).flatMap((file) => fileIdFromPath(file.path) ?? []);
	if (message?.role === "toolResult" && message.toolName === "send_file") {
		const files = (message.details as { files?: { id?: unknown }[] } | undefined)?.files ?? [];
		return files.flatMap((file) => (typeof file.id === "string" ? [file.id] : []));
	}
	return [];
}

/** An answer's spend, for the usage ledger. */
function usageRow(entry: EntryRecord): UsageRow | undefined {
	if (entry.kind !== "pi.assistant") return undefined;
	const message = entry.model?.[0] as
		| { provider?: string; model?: string; timestamp?: number; usage?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number; cost?: { total?: number } } }
		| undefined;
	const usage = message?.usage;
	if (usage === undefined || message?.provider === undefined || message.model === undefined) return undefined;
	return {
		entryId: entry.id,
		conversationId: entry.conversationId,
		time: message.timestamp ?? Date.now(),
		model: `${message.provider}/${message.model}`,
		input: usage.input ?? 0,
		output: usage.output ?? 0,
		cacheRead: usage.cacheRead ?? 0,
		cacheWrite: usage.cacheWrite ?? 0,
		cost: usage.cost?.total ?? 0,
	};
}

export class Search {
	readonly index: SearchIndex;
	readonly usage: UsageLedger;
	readonly #host: Host;
	#pendingUsage: UsageRow[] = [];
	readonly #unsubscribe: () => void;
	readonly #unsubscribeWarm: () => void;
	readonly #unsubscribeCompaction: () => void;
	/** Entries committed while the backfill runs, indexed after it. */
	#pending: IndexEntry[] = [];
	#flushScheduled = false;
	#backfilling = true;
	/** Where index writes go: this thread's index, or the backfill's worker while it runs. */
	#writer: IndexWriter;
	#worker: WorkerWriter | undefined;
	#closed = false;
	readonly ready: Promise<void>;

	/** `path`: the index file; ":memory:" for one that lives as long as the process. */
	constructor(host: Host, path: string) {
		this.#host = host;
		this.index = new SearchIndex(path);
		this.usage = new UsageLedger(this.index.db);
		this.#writer = localWriter(this.index, this.usage);
		// A file is backfilled from a worker thread; one in memory has no other connection, and nothing to catch up on.
		if (path !== ":memory:") this.#writer = this.#worker = new WorkerWriter(path);
		this.#unsubscribeWarm = host.cache.onWarm(({ conversationId, time, usage }) =>
			this.#writer.addWarm({ conversationId, time, input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, cost: usage.cost.total }),
		);
		this.#unsubscribeCompaction = host.compaction.onUsage(({ conversationId, time, usage }) =>
			this.#writer.addCompaction({ conversationId, time, input: usage.input, output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, cost: usage.cost.total }),
		);
		this.#unsubscribe = onCommit(host.harness, (publication) => {
			for (const change of publication.changes) {
				if (change.type === "entry") {
					this.#pending.push(indexEntry(change.value));
					const usage = usageRow(change.value);
					if (usage !== undefined) this.#pendingUsage.push(usage);
				} else if (change.type === "conversation") {
					this.#conversation(change.value);
				} else if (change.type === "document" && change.conversationId !== undefined && change.record.kind === MetaDoc.definition.kind) {
					const meta = changedValue(change) as { title?: string; archived?: boolean; hidden?: boolean } | null;
					this.#meta(change.conversationId, meta ?? {});
				}
			}
			this.#scheduleFlush();
		});
		this.ready = this.#backfill().catch((error) => console.error("[search] backfill failed:", error));
	}

	close(): void {
		this.#unsubscribe();
		this.#unsubscribeWarm();
		this.#unsubscribeCompaction();
		this.#closed = true;
		void this.#worker?.terminate();
		this.index.close();
	}

	#conversation(record: ConversationRecord): void {
		this.#writer.setConversation(record.id, record.parent === undefined ? {} : { parent: { conversationId: record.parent.conversationId, at: record.parent.at } });
	}

	#titles = new Map<number, string>();
	#archived = new Map<number, boolean>();
	/** Hidden conversations (MetaDoc.hidden): search leaves them out. */
	#hidden = new Set<number>();

	#meta(conversationId: number, meta: { title?: string; archived?: boolean; hidden?: boolean }): void {
		if (meta.hidden === true) this.#hidden.add(conversationId);
		else this.#hidden.delete(conversationId);
		const title = meta.title ?? "";
		if (this.#titles.get(conversationId) !== title) {
			this.#titles.set(conversationId, title);
			this.#writer.setTitle(conversationId, title);
		}
		const archived = meta.archived === true;
		if (this.#archived.get(conversationId) !== archived) {
			this.#archived.set(conversationId, archived);
			this.#writer.setArchived(conversationId, archived);
		}
	}

	#scheduleFlush(): void {
		if (this.#flushScheduled || this.#backfilling || (this.#pending.length === 0 && this.#pendingUsage.length === 0)) return;
		this.#flushScheduled = true;
		setImmediate(() => {
			this.#flushScheduled = false;
			const pending = this.#pending;
			const usage = this.#pendingUsage;
			this.#pending = [];
			this.#pendingUsage = [];
			try {
				this.index.add(pending);
				this.usage.add(usage);
			} catch (error) {
				console.error("[search] indexing failed:", error);
			}
		});
	}

	/**
	 * Every conversation's entries past what the index has, oldest first, a page at a time. Into a file the writes go to
	 * a worker thread: a first start over a large database indexes for minutes, and the server answers meanwhile.
	 */
	async #backfill(): Promise<void> {
		const { storage, harness } = this.#host;
		const context = BACKGROUND_CONTEXT;
		const started = performance.now();
		let indexed = 0;
		let cursor: Cursor | undefined;
		try {
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
						const own = batch.items.filter((entry) => entry.conversationId === conversation.id);
						this.#writer.add(own.map(indexEntry), own.flatMap((entry) => usageRow(entry) ?? []));
						indexed += own.length;
						entries = batch.next;
						await this.#worker?.room();
						// Let requests in between pages.
						await new Promise((resolve) => setImmediate(resolve));
					} while (entries !== undefined);
				}
				cursor = page.next;
			} while (cursor !== undefined);
			if (this.#worker !== undefined) {
				await this.#worker.finish();
				if (this.#closed) return;
				// The worker moved the conversations' cursors; from now on this thread writes.
				this.index.reload();
			}
		} catch (error) {
			await this.#worker?.terminate();
			// Closed while it ran: nothing failed.
			if (this.#closed) return;
			throw error;
		} finally {
			this.#worker = undefined;
			this.#writer = localWriter(this.index, this.usage);
		}
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
			// A conversation the index knows and the storage does not (one that never committed) has no excerpt.
			const found = await storage.entry(conversationId as ConversationId, entryId as EntryId, context).catch(() => undefined);
			return found === undefined ? undefined : partText(found.entry, idx);
		};
		return this.index.search(query, load, { ...options, hits: 1, exclude: this.#hidden });
	}

	/** What the models cost over the last `days` days (0: all), in the client's days. */
	async report(days: number, tzOffset: number): Promise<UsageReport> {
		await this.ready;
		return this.usage.report(days, tzOffset);
	}

	/** Whether an entry names the kept file, once the index has every entry. */
	async referencesFile(id: string): Promise<boolean> {
		await this.ready;
		return this.index.referencesFile(id);
	}

	/** One conversation's matching entries, newest first. */
	async searchConversation(conversationId: number, query: string, options: { kinds?: KindName[]; typing?: boolean }): Promise<ReturnType<SearchIndex["searchConversation"]>> {
		await this.ready;
		return this.index.searchConversation(conversationId, query, options);
	}
}
