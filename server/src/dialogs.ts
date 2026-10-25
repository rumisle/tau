// The chat list: one Dialog per conversation, computed once and kept current from the Session's commit stream, each
// change numbered so a client that reconnects gets only what changed since it last heard (docs/protocol.md).
import { randomUUID } from "node:crypto";
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
import type { SentFile } from "./send-file.ts";
import { FilesEntry, SubagentEntry } from "./shown.ts";
import { withoutQuotes } from "./quotes.ts";
import { type Host, MetaDoc, type MetaState } from "./host.ts";
import type { Dialog, EntrySummary } from "./protocol.ts";

const PREVIEW_CHARS = 200;
/** Unread counts stop here; a badge shows 99 at most. */
const MAX_UNREAD = 99;
/** Entries a recount reads back from the newest at most. */
const MAX_UNREAD_SCAN = 400;
/** Kinds a chat list never shows as the last message. */
const HIDDEN_KINDS: ReadonlySet<string> = new Set(["pi.system"]);

export type DialogListener = (dialog: Dialog, version: string) => void;
export type SubmissionListener = (record: SubmissionRecord) => void;

/** What a Dialog is made of, kept per conversation. New entries and run changes update it in place; anything else
 * reads it again. */
type DialogState = {
	conversation: ConversationRecord;
	meta: MetaState | undefined;
	agent: { model?: { provider: string; modelId: string } } | undefined;
	cache: CacheState | undefined;
	busy: boolean;
	last: EntrySummary | undefined;
	/** The last entry shown is a hidden kind's, for want of another. */
	lastHidden: boolean;
	unreadCount: number;
	/** The newest entry counted: an entry at or below it is in `last` and `unreadCount` already. */
	through: number;
};

type Kept = { state: DialogState; serialized: string; version: number };
/** What a conversation's commits changed since the last flush. */
type Change = { entries: EntryRecord[]; busy?: boolean; reread: boolean };

/**
 * Every conversation's Dialog, read from storage once (at start, in the background) and then kept current: a commit
 * that adds entries or starts or ends a run updates its conversation's Dialog from the commit itself; one that changes
 * its title, read mark, model or prompt cache reads that conversation again. Each Dialog that changes gets the next
 * version number, so `list(since)` returns only the Dialogs changed after a version, as long as this process gave it
 * (versions restart with the process: `epoch`).
 */
export class Dialogs {
	readonly #host: Host;
	readonly #dialogListeners = new Set<DialogListener>();
	readonly #submissionListeners = new Set<SubmissionListener>();
	readonly #kept = new Map<ConversationId, Kept>();
	readonly #epoch = randomUUID().slice(0, 8);
	#version = 0;
	#loaded = false;
	readonly #ready: Promise<void>;
	readonly #changes = new Map<ConversationId, Change>();
	#flushing = false;
	#closed = false;
	readonly #settled: (() => void)[] = [];
	readonly #unsubscribe: () => void;
	readonly #unsubscribeCache: () => void;

	constructor(host: Host) {
		this.#host = host;
		this.#unsubscribeCache = host.cache.onChange((id) => {
			this.#change(id).reread = true;
			this.#schedule();
		});
		this.#unsubscribe = host.harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type === "entry") this.#change(change.value.conversationId).entries.push(change.value);
				else if (change.type === "conversation") this.#change(change.value.id).reread = true;
				else if (change.type === "submission") {
					for (const listener of this.#submissionListeners) listener(change.value);
				} else if (change.type === "document" && change.conversationId !== undefined) {
					const kind = change.record.kind;
					if (kind === MetaDoc.definition.kind || kind === AgentDoc.definition.kind || kind === CacheDoc.definition.kind) this.#change(change.conversationId).reread = true;
					else if (kind === LiveDoc.definition.kind) {
						// pi.live changes on every streamed chunk; only a run starting or ending matters here.
						const busy = change.value !== null && (change.value as { run?: unknown }).run !== undefined;
						const pending = this.#changes.get(change.conversationId);
						const known = pending?.busy ?? this.#kept.get(change.conversationId)?.state.busy;
						if (!this.#loaded || known !== busy) this.#change(change.conversationId).busy = busy;
					}
				}
			}
			this.#schedule();
		});
		this.#ready = this.#load();
		// A failed load fails list() with it; nothing else waits on it.
		this.#ready.catch((error) => console.error("[tau] chat list load failed:", error));
	}

	close(): void {
		this.#closed = true;
		this.#changes.clear();
		for (const resolve of this.#settled.splice(0)) resolve();
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

	/** Resolves once every conversation's Dialog is read; `list` needs it. */
	ready(): Promise<void> {
		return this.#ready;
	}

	/** Resolves once what was committed so far is in the list: a list right after a request shows what it did. */
	settled(): Promise<void> {
		if (this.#closed || (this.#loaded && !this.#flushing && this.#changes.size === 0)) return Promise.resolve();
		return new Promise((resolve) => this.#settled.push(resolve));
	}

	/** The current version, for `list(since)` later. */
	get version(): string {
		return `${this.#epoch}:${this.#version}`;
	}

	/**
	 * The Dialogs changed after version `since`, or all of them (`full`) without one or for one this process did not
	 * give. Synchronous, after `ready()`: a listener added just before misses no change and repeats none.
	 */
	list(since?: string): { dialogs: Dialog[]; version: string; full: boolean } {
		if (!this.#loaded) throw new Error("The chat list is not loaded yet");
		const [epoch, number] = since?.split(":") ?? [];
		const after = epoch === this.#epoch && number !== undefined && /^\d+$/.test(number) && Number(number) <= this.#version ? Number(number) : undefined;
		const kept = [...this.#kept.values()].filter((each) => after === undefined || each.version > after);
		kept.sort((a, b) => (b.state.last?.id ?? 0) - (a.state.last?.id ?? 0));
		return { dialogs: kept.map((each) => JSON.parse(each.serialized) as Dialog), version: this.version, full: after === undefined };
	}

	/** A conversation's Dialog read now, as a create or fork returns it. */
	async dialog(conversation: ConversationRecord, context: Context): Promise<Dialog> {
		return this.#render(await this.#read(conversation, context));
	}

	#change(id: ConversationId): Change {
		let change = this.#changes.get(id);
		if (change === undefined) {
			change = { entries: [], reread: false };
			this.#changes.set(id, change);
		}
		return change;
	}

	#schedule(): void {
		if (this.#closed || this.#flushing || !this.#loaded || this.#changes.size === 0) return;
		this.#flushing = true;
		// Commit listeners must not call Session APIs; apply after the commit, coalescing a burst of commits.
		setTimeout(() => void this.#flush(), 16);
	}

	async #load(): Promise<void> {
		let cursor: Cursor | undefined;
		do {
			const page = await this.#host.storage.scanConversations({}, 200, cursor, BACKGROUND_CONTEXT);
			for (const conversation of page.items) {
				if (this.#closed) return;
				const state = await this.#read(conversation, BACKGROUND_CONTEXT);
				this.#keep(state, false);
			}
			cursor = page.next;
		} while (cursor !== undefined);
		// What changed during the load is read again: the state read may be older or newer than the change.
		for (const change of this.#changes.values()) change.reread = true;
		this.#loaded = true;
		this.#schedule();
		if (!this.#flushing) for (const resolve of this.#settled.splice(0)) resolve();
	}

	async #flush(): Promise<void> {
		try {
			while (this.#changes.size > 0 && !this.#closed) {
				const changes = [...this.#changes];
				this.#changes.clear();
				for (const [id, change] of changes) {
					const kept = this.#kept.get(id);
					let state: DialogState | undefined;
					if (change.reread || kept === undefined) {
						const conversation = await this.#host.storage.conversation(id, BACKGROUND_CONTEXT);
						if (conversation === undefined) continue;
						state = await this.#read(conversation, BACKGROUND_CONTEXT);
					} else {
						state = { ...kept.state };
						for (const entry of change.entries) count(state, entry);
						if (change.busy !== undefined) state.busy = change.busy;
					}
					this.#keep(state, true);
				}
			}
		} catch (error) {
			console.error("[tau] dialog update failed:", error);
		} finally {
			this.#flushing = false;
			this.#schedule();
			if (!this.#flushing) for (const resolve of this.#settled.splice(0)) resolve();
		}
	}

	/** Keeps a conversation's state; a Dialog that changed gets the next version and goes to the listeners. */
	#keep(state: DialogState, emit: boolean): void {
		const dialog = this.#render(state);
		const serialized = JSON.stringify(dialog);
		const id = state.conversation.id;
		const kept = this.#kept.get(id);
		if (kept?.serialized === serialized) {
			kept.state = state;
			return;
		}
		this.#version += 1;
		this.#kept.set(id, { state, serialized, version: this.#version });
		if (!emit) return;
		for (const listener of this.#dialogListeners) listener(dialog, this.version);
	}

	async #read(conversation: ConversationRecord, context: Context): Promise<DialogState> {
		const { harness } = this.#host;
		const handle = await harness.conversation(conversation.id, context);
		const meta = await harness.snapshot(MetaDoc, conversation.id, context);
		const live = await harness.snapshot(LiveDoc, conversation.id, context);
		const agent = await harness.snapshot(AgentDoc, conversation.id, context);
		const cache = await harness.snapshot(CacheDoc, conversation.id, context);
		const state: DialogState = {
			conversation,
			meta,
			agent: agent === undefined ? undefined : { ...(agent.model === undefined ? {} : { model: agent.model }) },
			cache,
			busy: live?.run !== undefined,
			last: undefined,
			lastHidden: false,
			unreadCount: 0,
			through: 0,
		};
		if (handle !== undefined) {
			// Newest first: the last message, and the assistant messages after the read mark.
			const read = meta?.read ?? 0;
			let page = await handle.entries({}, 32, undefined, context);
			state.through = page.items[0]?.id ?? 0;
			const shown = page.items.find((entry) => !HIDDEN_KINDS.has(entry.kind));
			const last = shown ?? page.items[0];
			if (last !== undefined) {
				state.last = summarize(last);
				state.lastHidden = shown === undefined;
			}
			let scanned = 0;
			scan: for (;;) {
				for (const entry of page.items) {
					if (entry.id <= read || state.unreadCount >= MAX_UNREAD) break scan;
					if (isAnswer(entry)) state.unreadCount += 1;
				}
				scanned += page.items.length;
				if (page.next === undefined || scanned >= MAX_UNREAD_SCAN) break;
				page = await handle.entries({}, 32, page.next, context);
			}
		}
		return state;
	}

	#render(state: DialogState): Dialog {
		const { conversation, meta, agent, cache } = state;
		return {
			conversation,
			...(meta?.title === undefined ? {} : { title: meta.title }),
			...(meta?.createdAt === undefined ? {} : { createdAt: meta.createdAt }),
			...(state.last === undefined ? {} : { last: state.last }),
			agent: {
				...(agent?.model === undefined ? {} : { model: agent.model }),
			},
			busy: state.busy,
			...(meta?.read === undefined ? {} : { read: meta.read as EntryId }),
			unreadCount: state.unreadCount,
			...(meta?.markedUnread === true ? { markedUnread: true as const } : {}),
			...(meta?.archived === true ? { archived: true as const } : {}),
			...(meta?.hidden === true ? { hidden: true as const } : {}),
			...(typeof meta?.pinned === "number" ? { pinned: meta.pinned } : {}),
			...promptCache(cache, cacheModel(agent?.model ?? this.#host.defaultModel), this.#host.cache.warming(conversation.id)),
		};
	}
}

/** A new entry into a conversation's state, as `#read` would have counted it; one counted already changes nothing. */
function count(state: DialogState, entry: EntryRecord): void {
	if (entry.id <= state.through) return;
	state.through = entry.id;
	if (!HIDDEN_KINDS.has(entry.kind) || state.last === undefined || state.lastHidden) {
		state.last = summarize(entry);
		state.lastHidden = HIDDEN_KINDS.has(entry.kind);
	}
	if (entry.id > (state.meta?.read ?? 0) && state.unreadCount < MAX_UNREAD && isAnswer(entry)) state.unreadCount += 1;
}

/** An assistant message with text: what a reader counts as a message, unlike tool-call steps. */
/**
 * A Dialog's prompt cache: the entry while it is in the cache of the conversation's model, the next request's (the
 * last one may have gone to another model, or the model changed since), and the refresh counters, which are the
 * conversation's whatever its model.
 */
export function promptCache(cache: CacheState | undefined, model: string, warming: { until?: number } | undefined): { cache?: Dialog["cache"] } {
	if (cache === undefined) return {};
	const current = cache.model === model && cache.ttl !== undefined && cache.at !== undefined;
	const counters = cache.warms !== undefined && cache.warms > 0;
	if (!current && !counters) return {};
	return {
		cache: {
			...(current
				? { ttl: cache.ttl!, at: cache.at!, ...(warming === undefined ? {} : { warming: true as const, ...(warming.until === undefined ? {} : { until: warming.until }) }) }
				: {}),
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
		// What a script did (src/shown.ts), until its result comes.
		case FilesEntry.kind: {
			const files = (entry.data as { files: SentFile[] }).files;
			const images = files.filter((file) => file.mimeType.startsWith("image/")).length;
			if (images === files.length) return images > 1 ? `${images} Photos` : "Photo";
			return files.length > 1 ? `${files.length} Files` : files[0]!.name;
		}
		case SubagentEntry.kind:
			return "→ subagent";
	}
	if (message === undefined) return typeof entry.data === "string" ? entry.data : entry.kind;
	switch (message.role) {
		case "user": {
			if (typeof message.content === "string") return withoutQuotes(message.content);
			// A caption stands for its photos and files, as in Telegram's chat list; photos alone read "Photo", a file
			// its name.
			const text = withoutQuotes(ownText(message.content)).replace(/\n/g, " ");
			if (text.trim() !== "") return text;
			const files = attachedFiles(message.content).filter((file) => file.kind === "file");
			if (files.length > 0) return files.length > 1 ? `${files.length} Files` : (files[0]!.path.split("/").at(-1) ?? "File");
			const images = message.content.filter((part) => part.type === "image").length;
			return images > 1 ? `${images} Photos` : "Photo";
		}
		case "assistant": {
			const text = withoutQuotes(
				message.content
					.filter((part) => part.type === "text")
					.map((part) => part.text)
					.join(" "),
			);
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
