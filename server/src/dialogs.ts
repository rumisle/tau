// The chat list: one Dialog per conversation, kept current from the Session's commit stream.
import type { Context } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Message } from "@earendil-works/pi-ai";
import {
	AgentDoc,
	type ConversationId,
	type ConversationRecord,
	type Cursor,
	type EntryId,
	type EntryRecord,
	LiveDoc,
	type SubmissionRecord,
} from "@earendil-works/pi-durable";
import { CacheDoc, type CacheState, cacheModel } from "./cache.ts";
import { attachedFiles, ownText } from "./attachments.ts";
import { type Host, MetaDoc } from "./host.ts";
import type { Dialog, EntrySummary } from "./protocol.ts";

const PREVIEW_CHARS = 200;
/** Unread counts stop here; a badge shows 99 at most. */
const MAX_UNREAD = 99;
/** Kinds a chat list never shows as the last message. */
const HIDDEN_KINDS: ReadonlySet<string> = new Set(["pi.system"]);

export type DialogListener = (dialog: Dialog) => void;
export type SubmissionListener = (record: SubmissionRecord) => void;

/**
 * Watches every commit once for all connections. A commit that touches a conversation's entries, title, or busy state
 * schedules a recompute of its Dialog; listeners get it only when it changed.
 */
export class Dialogs {
	readonly #host: Host;
	readonly #dialogListeners = new Set<DialogListener>();
	readonly #submissionListeners = new Set<SubmissionListener>();
	/** Last emitted Dialog per conversation, serialized, to drop no-op updates. */
	readonly #emitted = new Map<ConversationId, string>();
	readonly #busy = new Map<ConversationId, boolean>();
	readonly #dirty = new Set<ConversationId>();
	#flushing = false;
	readonly #unsubscribe: () => void;
	readonly #unsubscribeCache: () => void;

	constructor(host: Host) {
		this.#host = host;
		this.#unsubscribeCache = host.cache.onChange((id) => this.#touch(id));
		this.#unsubscribe = host.harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type === "entry") this.#touch(change.value.conversationId);
				else if (change.type === "conversation") this.#touch(change.value.id);
				else if (change.type === "submission") {
					for (const listener of this.#submissionListeners) listener(change.value);
				} else if (change.type === "document" && change.conversationId !== undefined) {
					const kind = change.record.kind;
					if (kind === MetaDoc.definition.kind || kind === AgentDoc.definition.kind || kind === CacheDoc.definition.kind) this.#touch(change.conversationId);
					else if (kind === LiveDoc.definition.kind) {
						// pi.live changes on every streamed chunk; only a run starting or ending matters here.
						const busy = change.value !== null && (change.value as { run?: unknown }).run !== undefined;
						if (this.#busy.get(change.conversationId) !== busy) {
							this.#busy.set(change.conversationId, busy);
							this.#touch(change.conversationId);
						}
					}
				}
			}
		});
	}

	close(): void {
		this.#unsubscribe();
		this.#unsubscribeCache();
		this.#dialogListeners.clear();
		this.#submissionListeners.clear();
	}

	onDialog(listener: DialogListener): () => void {
		this.#dialogListeners.add(listener);
		return () => this.#dialogListeners.delete(listener);
	}

	onSubmission(listener: SubmissionListener): () => void {
		this.#submissionListeners.add(listener);
		return () => this.#submissionListeners.delete(listener);
	}

	async list(context: Context): Promise<Dialog[]> {
		const dialogs: Dialog[] = [];
		let cursor: Cursor | undefined;
		do {
			const page = await this.#host.storage.scanConversations({}, 200, cursor, context);
			for (const conversation of page.items) dialogs.push(await this.dialog(conversation, context));
			cursor = page.next;
		} while (cursor !== undefined);
		dialogs.sort((a, b) => (b.last?.id ?? 0) - (a.last?.id ?? 0));
		for (const dialog of dialogs) this.#emitted.set(dialog.conversation.id, JSON.stringify(dialog));
		return dialogs;
	}

	async dialog(conversation: ConversationRecord, context: Context): Promise<Dialog> {
		const { harness } = this.#host;
		const handle = await harness.conversation(conversation.id, context);
		const meta = await harness.snapshot(MetaDoc, conversation.id, context);
		const live = await harness.snapshot(LiveDoc, conversation.id, context);
		const agent = await harness.snapshot(AgentDoc, conversation.id, context);
		const cache = await harness.snapshot(CacheDoc, conversation.id, context);
		let last: EntryRecord | undefined;
		let unreadCount = 0;
		if (handle !== undefined) {
			// Newest first: the last message, and the assistant messages after the read mark.
			const read = meta?.read ?? 0;
			let page = await handle.entries({}, 32, undefined, context);
			last = page.items.find((entry) => !HIDDEN_KINDS.has(entry.kind)) ?? page.items[0];
			let scanned = 0;
			scan: for (;;) {
				for (const entry of page.items) {
					if (entry.id <= read || unreadCount >= MAX_UNREAD) break scan;
					if (isAnswer(entry)) unreadCount += 1;
				}
				scanned += page.items.length;
				if (page.next === undefined || scanned >= 400) break;
				page = await handle.entries({}, 32, page.next, context);
			}
		}
		const busy = live?.run !== undefined;
		this.#busy.set(conversation.id, busy);
		return {
			conversation,
			...(meta?.title === undefined ? {} : { title: meta.title }),
			...(meta?.createdAt === undefined ? {} : { createdAt: meta.createdAt }),
			...(last === undefined ? {} : { last: summarize(last) }),
			agent: {
				...(agent?.model === undefined ? {} : { model: agent.model }),
				cwd: agent?.cwd ?? this.#host.cwd,
			},
			busy,
			...(meta?.read === undefined ? {} : { read: meta.read as EntryId }),
			unreadCount,
			...(meta?.markedUnread === true ? { markedUnread: true as const } : {}),
			...(meta?.archived === true ? { archived: true as const } : {}),
			...(meta?.hidden === true ? { hidden: true as const } : {}),
			...(typeof meta?.pinned === "number" ? { pinned: meta.pinned } : {}),
			...promptCache(cache, cacheModel(agent?.model ?? this.#host.defaultModel), this.#host.cache.isWarming(conversation.id)),
		};
	}

	#touch(id: ConversationId): void {
		if (this.#dialogListeners.size === 0) return;
		this.#dirty.add(id);
		if (this.#flushing) return;
		this.#flushing = true;
		// Commit listeners must not call Session APIs; recompute after the commit, coalescing a burst of commits.
		setTimeout(() => void this.#flush(), 16);
	}

	async #flush(): Promise<void> {
		try {
			while (this.#dirty.size > 0) {
				const ids = [...this.#dirty];
				this.#dirty.clear();
				for (const id of ids) {
					const conversation = await this.#host.storage.conversation(id, BACKGROUND_CONTEXT);
					if (conversation === undefined) continue;
					const dialog = await this.dialog(conversation, BACKGROUND_CONTEXT);
					const serialized = JSON.stringify(dialog);
					if (this.#emitted.get(id) === serialized) continue;
					this.#emitted.set(id, serialized);
					for (const listener of this.#dialogListeners) listener(dialog);
				}
			}
		} catch (error) {
			console.error("[tau] dialog update failed:", error);
		} finally {
			this.#flushing = false;
		}
	}
}

/** An assistant message with text: what a reader counts as a message, unlike tool-call steps. */
/**
 * A Dialog's prompt cache: the entry while it is in the cache of the conversation's model, the next request's (the
 * last one may have gone to another model, or the model changed since), and the refresh counters, which are the
 * conversation's whatever its model.
 */
export function promptCache(cache: CacheState | undefined, model: string, warming: boolean): { cache?: Dialog["cache"] } {
	if (cache === undefined) return {};
	const current = cache.model === model && cache.ttl !== undefined && cache.at !== undefined;
	const counters = cache.warms !== undefined && cache.warms > 0;
	if (!current && !counters) return {};
	return {
		cache: {
			...(current ? { ttl: cache.ttl!, at: cache.at!, ...(warming ? { warming: true as const } : {}) } : {}),
			...(counters ? { warms: cache.warms!, cost: cache.cost ?? 0, saved: cache.saved ?? 0 } : {}),
		},
	};
}

function isAnswer(entry: EntryRecord): boolean {
	const message = entry.model?.[0];
	return message?.role === "assistant" && message.content.some((part) => part.type === "text" && part.text.trim() !== "");
}

/** A one-line preview of an entry for the chat list. */
export function summarize(entry: EntryRecord): EntrySummary {
	const message = entry.model?.[0];
	const summary: EntrySummary = { id: entry.id, kind: entry.kind, text: "" };
	if (message !== undefined) {
		summary.role = message.role;
		summary.timestamp = message.timestamp;
	}
	summary.text = preview(previewText(entry, message));
	return summary;
}

function previewText(entry: EntryRecord, message: Message | undefined): string {
	switch (entry.kind) {
		case "pi.reset":
			return "New context";
		case "pi.compaction":
			return "Context compacted";
	}
	if (message === undefined) return typeof entry.data === "string" ? entry.data : entry.kind;
	switch (message.role) {
		case "user": {
			if (typeof message.content === "string") return message.content;
			// A caption stands for its photos and files, as in Telegram's chat list; photos alone read "Photo", a file
			// its name.
			const text = ownText(message.content).replace(/\n/g, " ");
			if (text.trim() !== "") return text;
			const files = attachedFiles(message.content).filter((file) => file.kind === "file");
			if (files.length > 0) return files.length > 1 ? `${files.length} Files` : (files[0]!.path.split("/").at(-1) ?? "File");
			const images = message.content.filter((part) => part.type === "image").length;
			return images > 1 ? `${images} Photos` : "Photo";
		}
		case "assistant": {
			const text = message.content
				.filter((part) => part.type === "text")
				.map((part) => part.text)
				.join(" ");
			if (text.trim() !== "") return text;
			const calls = message.content.filter((part) => part.type === "toolCall").map((part) => part.name);
			if (calls.length > 0) return `→ ${calls.join(", ")}`;
			return message.errorMessage ?? "";
		}
		case "toolResult": {
			const text = message.content
				.filter((part) => part.type === "text")
				.map((part) => part.text)
				.join(" ");
			return `${message.toolName}: ${text}`;
		}
		default:
			return "";
	}
}

function preview(text: string): string {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length <= PREVIEW_CHARS ? flat : `${flat.slice(0, PREVIEW_CHARS - 1)}…`;
}
