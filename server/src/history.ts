// history_read and history_search (docs/history.md): an agent reads and searches the server's conversations, its own
// past its compaction, its subagents', its owner's, and any the user links to. Both name everything by tau's links
// (docs/links.md) and return the same JSON to the model and to a code mode script.
import type { Context } from "@earendil-works/chord";
import { type AssistantMessage, type Message, Type } from "@earendil-works/pi-ai";
import {
	type ConversationId,
	type Cursor,
	defineExtension,
	defineTool,
	type EntryId,
	type EntryRecord,
	type Extension,
	type Harness,
	LiveDoc,
	type Storage,
} from "@earendil-works/pi-durable";
import { MetaDoc } from "./host.ts";
import { cut, HISTORY_KINDS, type HistoryKind, toolCallText, toolOutputText, userText } from "./history-text.ts";
import { modelCallId } from "./shown.ts";
import { Subagents } from "./subagent.ts";

/** What history reads from: the Harness for documents and contexts, the storage for entries, the server's ID for links. */
export type HistoryHost = { readonly harness: Harness; readonly storage: Storage; readonly serverId: string };

export class HistoryError extends Error {}

/** A window's part: at most this much of it, the rest by its `next`. */
const PART_LINES = 40;
const PART_BYTES = 2_000;
/** An entry read alone: as much as `read` shows of a file. */
const ALONE_LINES = 2_000;
const ALONE_BYTES = 50 * 1024;
/** How far a call's result is looked for after it. */
const RESULT_SCAN = 500;

export type Part = {
	kind: HistoryKind;
	/** A tool's name, for its call and its output. */
	name?: string;
	text: string;
	images?: number;
	/** A failed model response, or a tool's error result. */
	error?: true;
	/** A compaction's summary, which stands for what came before it. */
	summary?: true;
	truncated?: { lines: number; bytes: number };
	next?: ReadArgs;
};

export type ReadEntry = { id: number; time?: string; inContext?: boolean; parts: Part[] };

export type ChatCard = {
	link: string;
	title: string;
	status: "working" | "idle";
	owner?: { link: string; title: string };
	forkOf?: { link: string };
	subagents?: { name: string; link: string; status: "working" | "idle" }[];
};

export type ReadArgs = { link?: string; kinds?: HistoryKind[]; older?: number; newer?: number; part?: number; offset?: number; truncate?: boolean };
export type ReadResult = { chat: ChatCard; entries: ReadEntry[]; older: ReadArgs | null; newer: ReadArgs | null };

/** A conversation, or one of its entries, as a link or an alias names it. */
export type Address = { conversation: ConversationId; entry?: EntryId };

const LINK = /^tau:\/\/([0-9a-z]+)\/(\d+)(?:\/(\d+))?\/?(?:\?.*)?$/i;

export class History {
	readonly #hostOf: () => HistoryHost;

	/** `host`: read when used, as the Harness opens after its tools are installed. */
	constructor(host: () => HistoryHost) {
		this.#hostOf = host;
	}

	get #host(): HistoryHost {
		return this.#hostOf();
	}

	/** This server's name in links: the first eight characters of its ID. */
	get server(): string {
		return this.#host.serverId.slice(0, 8).toLowerCase();
	}

	link(conversation: number, entry?: number): string {
		return `tau://${this.server}/${conversation}${entry === undefined ? "" : `/${entry}`}`;
	}

	/** `this`, `owner`, or a link of this server; `subagents` is search's only. */
	async address(value: string, caller: ConversationId, context: Context): Promise<Address> {
		const given = value.trim();
		if (given === "this") return { conversation: caller };
		if (given === "owner") {
			const owner = (await this.#host.storage.conversation(caller, context))?.owner?.conversationId;
			if (owner === undefined) throw new HistoryError("This chat has no owner: no other chat started it.");
			return { conversation: owner };
		}
		if (given === "subagents") throw new HistoryError("subagents names several chats: search them with in, then read one by its link.");
		const match = LINK.exec(given);
		if (match === null) throw new HistoryError(`Not a chat's link: ${given}. Use a tau:// link, "this" or "owner".`);
		if (match[1]!.toLowerCase() !== this.server) throw new HistoryError(`Not on this server: ${given} is a chat of another server.`);
		const conversation = Number(match[2]) as ConversationId;
		if ((await this.#host.storage.conversation(conversation, context)) === undefined) throw new HistoryError(`No chat ${conversation} on this server.`);
		return { conversation, ...(match[3] === undefined ? {} : { entry: Number(match[3]) as EntryId }) };
	}

	/** A conversation's card: who it is, and who it is related to. */
	async card(id: ConversationId, context: Context): Promise<ChatCard> {
		const { harness, storage } = this.#host;
		const record = await storage.conversation(id, context);
		const busy = async (conversation: ConversationId) => ((await harness.snapshot(LiveDoc, conversation, context))?.run === undefined ? "idle" : "working") as "idle" | "working";
		const title = async (conversation: ConversationId) => (await harness.snapshot(MetaDoc, conversation, context))?.title ?? "";
		const card: ChatCard = { link: this.link(id), title: await title(id), status: await busy(id) };
		const owner = record?.owner?.conversationId;
		if (owner !== undefined) card.owner = { link: this.link(owner), title: await title(owner) };
		if (record?.parent !== undefined) card.forkOf = { link: this.link(record.parent.conversationId, record.parent.at) };
		const agents = (await harness.snapshot(Subagents, id, context))?.agents ?? {};
		const names = Object.keys(agents);
		if (names.length > 0) {
			card.subagents = [];
			for (const name of names) card.subagents.push({ name, link: this.link(agents[name]!.conversationId), status: await busy(agents[name]!.conversationId) });
		}
		return card;
	}

	/** The subagents of a conversation, by its `tau.subagents` document. */
	async subagents(id: ConversationId, context: Context): Promise<ConversationId[]> {
		const agents = (await this.#host.harness.snapshot(Subagents, id, context))?.agents ?? {};
		return Object.values(agents).map((agent) => agent.conversationId);
	}

	/** The entries of `caller`'s context that the model reads, for `inContext`. */
	async inContext(caller: ConversationId, context: Context): Promise<Set<number>> {
		const conversation = await this.#host.harness.conversation(caller, context);
		if (conversation === undefined) return new Set();
		const view = await conversation.context(context);
		return new Set(view.entries.flatMap((entry, index) => ((view.contributions[index]?.length ?? 0) > 0 ? [entry.id as number] : [])));
	}

	/** The call a tool result answers: the assistant entry before it with the call. */
	async callOf(conversation: ConversationId, result: EntryRecord, context: Context): Promise<EntryRecord | undefined> {
		const callId = (result.model?.[0] as { toolCallId?: string } | undefined)?.toolCallId;
		if (callId === undefined) return undefined;
		let found: EntryRecord | undefined;
		await this.#scan(conversation, { maxEntryId: (result.id - 1) as EntryId, order: "descending" }, RESULT_SCAN, (entry) => {
			if (entry.kind === "pi.assistant" && toolCalls(entry).some((call) => call.id === callId)) {
				found = entry;
				return false;
			}
			return true;
		}, context);
		return found;
	}

	async read(caller: ConversationId, args: ReadArgs, context: Context): Promise<ReadResult> {
		const target = await this.address(args.link ?? "this", caller, context);
		const id = target.conversation;
		const kinds = new Set<HistoryKind>((args.kinds ?? HISTORY_KINDS).filter((kind) => kind !== "title"));
		if (kinds.size === 0) throw new HistoryError("kinds names nothing an entry has: title is a chat's, not an entry's.");
		const whole = args.truncate === false;
		const older = Math.max(0, args.older ?? (target.entry === undefined ? 9 : 3));
		const newer = Math.max(0, args.newer ?? (target.entry === undefined ? 0 : 3));
		const shows = (entry: EntryRecord) => possibleKinds(entry).some((kind) => kinds.has(kind));

		// The anchor: the entry linked (a result's own link reads as its call's), or the newest one shown.
		let anchor: EntryRecord | undefined;
		if (target.entry !== undefined) {
			anchor = (await this.#host.storage.entry(id, target.entry, context))?.entry;
			if (anchor === undefined) throw new HistoryError(`No entry ${target.entry} in ${this.link(id)}.`);
			if (anchor.kind === "pi.tool-result") anchor = (await this.callOf(id, anchor, context)) ?? anchor;
		} else {
			await this.#scan(id, { order: "descending" }, Number.POSITIVE_INFINITY, (entry) => {
				if (!shows(entry)) return true;
				anchor = entry;
				return false;
			}, context);
		}
		const card = await this.card(id, context);
		if (anchor === undefined) return { chat: card, entries: [], older: null, newer: null };

		// The window: `older` shown entries before the anchor and `newer` after it, one more each way to know there is more.
		const before: EntryRecord[] = [];
		await this.#scan(id, { maxEntryId: (anchor.id - 1) as EntryId, order: "descending" }, Number.POSITIVE_INFINITY, (entry) => {
			if (shows(entry)) before.push(entry);
			return before.length <= older;
		}, context);
		const after: EntryRecord[] = [];
		await this.#scan(id, { minEntryId: (anchor.id + 1) as EntryId, order: "ascending" }, Number.POSITIVE_INFINITY, (entry) => {
			if (shows(entry)) after.push(entry);
			return after.length <= newer;
		}, context);
		const window = [...before.slice(0, older).reverse(), ...(shows(anchor) || target.entry !== undefined ? [anchor] : []), ...after.slice(0, newer)];

		const results = await this.#results(id, window, context);
		const active = id === caller ? await this.inContext(caller, context) : undefined;
		const alone = older === 0 && newer === 0 && target.entry !== undefined;
		const entries = window.map((entry) => {
			let parts = entryParts(entry, results).filter((part) => kinds.has(part.kind));
			const link = this.link(id, entry.id);
			if (alone && args.part !== undefined) parts = parts.filter((_, index) => index === args.part);
			const shown = parts.map((part, index) => {
				if (whole) return part;
				const number = alone && args.part !== undefined ? args.part : index;
				const tail = !alone && part.kind === "tool_output";
				const piece = cut(part.text, alone ? { maxLines: ALONE_LINES, maxBytes: ALONE_BYTES, offset: args.offset ?? 1 } : { maxLines: PART_LINES, maxBytes: PART_BYTES, tail });
				if (piece.truncated === undefined) return part;
				const offset = tail ? 1 : piece.nextLine;
				return {
					...part,
					text: piece.text,
					truncated: piece.truncated,
					...(offset === undefined ? {} : { next: { link, older: 0, newer: 0, ...(parts.length > 1 || args.part !== undefined ? { part: number } : {}), offset } }),
				};
			});
			const time = entryTime(entry);
			const read: ReadEntry = { id: entry.id, ...(time === undefined ? {} : { time: iso(time) }), ...(active === undefined ? {} : { inContext: active.has(entry.id) }), parts: shown };
			return read;
		});
		// Paging: the entry before the first shown with as many again, or after the last.
		const page = (count: number) => (count === 0 ? 9 : count);
		const olderNext = before.length > older ? { link: this.link(id, before[older]!.id), older: page(older), newer: 0, ...(args.kinds === undefined ? {} : { kinds: args.kinds }) } : null;
		const newerNext = after.length > newer ? { link: this.link(id, after[newer]!.id), older: 0, newer: page(newer), ...(args.kinds === undefined ? {} : { kinds: args.kinds }) } : null;
		return { chat: card, entries, older: olderNext, newer: newerNext };
	}

	/** The results of the calls in `entries`, by call ID: after each call, as durable writes them. */
	async #results(id: ConversationId, entries: readonly EntryRecord[], context: Context): Promise<Map<string, EntryRecord>> {
		const wanted = new Set<string>();
		let first: number | undefined;
		for (const entry of entries) {
			for (const call of toolCalls(entry)) {
				wanted.add(call.id);
				first ??= entry.id;
			}
		}
		const results = new Map<string, EntryRecord>();
		if (first === undefined) return results;
		await this.#scan(id, { minEntryId: (first + 1) as EntryId, order: "ascending" }, RESULT_SCAN + entries.length, (entry) => {
			const callId = entry.kind === "pi.tool-result" ? (entry.model?.[0] as { toolCallId?: string } | undefined)?.toolCallId : undefined;
			if (callId !== undefined && wanted.has(callId)) {
				results.set(callId, entry);
				wanted.delete(callId);
			}
			return wanted.size > 0;
		}, context);
		return results;
	}

	/** Entries of a conversation (a fork's include its origin's) in order, until `visit` returns false or `max` were read. */
	async #scan(id: ConversationId, query: { minEntryId?: EntryId; maxEntryId?: EntryId; order: "ascending" | "descending" }, max: number, visit: (entry: EntryRecord) => boolean, context: Context): Promise<void> {
		let cursor: Cursor | undefined;
		let read = 0;
		do {
			const page = await this.#host.storage.scanEntries({ conversationId: id, ...query }, 64, cursor, context);
			for (const entry of page.items) {
				read += 1;
				if (!visit(entry) || read >= max) return;
			}
			cursor = page.next;
		} while (cursor !== undefined);
	}
}

type Call = { id: string; name: string; arguments: unknown };

function toolCalls(entry: EntryRecord): Call[] {
	if (entry.kind !== "pi.assistant") return [];
	const message = entry.model?.[0] as AssistantMessage | undefined;
	return (message?.content ?? []).flatMap((block) => (block.type === "toolCall" ? [{ id: block.id, name: block.name, arguments: block.arguments }] : []));
}

/** The kinds of part an entry may have, without its calls' results. */
export function possibleKinds(entry: EntryRecord): HistoryKind[] {
	const message = entry.model?.[0] as Message | undefined;
	if (message === undefined) return [];
	if (entry.kind === "pi.user" && message.role === "user") return [isReport(message) ? "assistant" : "user"];
	if (entry.kind === "pi.compaction") return ["assistant"];
	if (entry.kind !== "pi.assistant" || message.role !== "assistant") return [];
	if (message.stopReason === "error") return ["assistant"];
	const kinds = new Set<HistoryKind>();
	for (const block of message.content) {
		if (block.type === "text" && block.text.trim() !== "") kinds.add("assistant");
		else if (block.type === "thinking" && block.thinking.trim() !== "") kinds.add("reasoning");
		else if (block.type === "toolCall") {
			kinds.add("tool_call");
			kinds.add("tool_output");
		}
	}
	return [...kinds];
}

function isReport(message: Extract<Message, { role: "user" }>): boolean {
	return userText(message).text.startsWith("<subagent ");
}

/** An entry's parts in order, each call followed by its result. */
export function entryParts(entry: EntryRecord, results: ReadonlyMap<string, EntryRecord>): Part[] {
	const message = entry.model?.[0] as Message | undefined;
	if (message === undefined) return [];
	if (entry.kind === "pi.user" && message.role === "user") {
		const { text, images } = userText(message);
		return [{ kind: isReport(message) ? "assistant" : "user", text, ...(images > 0 ? { images } : {}) }];
	}
	if (entry.kind === "pi.compaction") {
		const text = message.role === "user" ? userText(message).text : "";
		return [{ kind: "assistant", text, summary: true }];
	}
	if (entry.kind !== "pi.assistant" || message.role !== "assistant") return [];
	const parts: Part[] = [];
	for (const block of message.content) {
		if (block.type === "text" && block.text.trim() !== "") parts.push({ kind: "assistant", text: block.text });
		else if (block.type === "thinking" && block.thinking.trim() !== "") parts.push({ kind: "reasoning", text: block.thinking });
		else if (block.type === "toolCall") {
			parts.push({ kind: "tool_call", name: block.name, text: toolCallText(block.name, block.arguments) });
			const result = results.get(block.id);
			const output = result?.model?.[0] as Message | undefined;
			if (output?.role === "toolResult") {
				const images = output.content.filter((part) => part.type === "image").length;
				parts.push({ kind: "tool_output", name: block.name, text: toolOutputText(output), ...(images > 0 ? { images } : {}), ...(output.isError ? { error: true as const } : {}) });
			}
		}
	}
	if (message.stopReason === "error") parts.push({ kind: "assistant", text: message.errorMessage ?? "The model returned an error.", error: true });
	return parts;
}

export function entryTime(entry: EntryRecord): number | undefined {
	return (entry.model?.[0] as { timestamp?: number } | undefined)?.timestamp;
}

export function iso(time: number): string {
	return new Date(time).toISOString().replace(/\.\d{3}Z$/, "Z");
}

const KIND = Type.Union(HISTORY_KINDS.map((kind) => Type.Literal(kind)));

const READ_DESCRIPTION =
	"Read a chat of this server, yours included: past your compaction, a subagent's, your owner's (the chat that started " +
	"you), or one a tau:// link names. link: a chat (its newest entries) or an entry (it and 3 on each side), or " +
	'"this" (default) or "owner". older/newer size the window; older: 0, newer: 0 reads one entry whole. The result: ' +
	"chat (link, title, status, owner, forkOf, subagents), entries (id; an entry's link is chat.link + /id; parts by " +
	"kind: user, assistant, reasoning, tool_call, tool_output), and older/newer: the arguments to call again for the " +
	"entries before or after. A cut part has next: the arguments to read the rest. kinds narrows the parts shown.";

/** The two tools, over `history` (and a search index, once there is one: `search()`). */
export function historyExtension(history: History): Extension {
	const read = defineTool({
		name: "history_read",
		description: READ_DESCRIPTION,
		parameters: Type.Object({
			link: Type.Optional(Type.String({ description: 'A tau:// link to a chat or an entry, "this" or "owner"' })),
			kinds: Type.Optional(Type.Array(KIND)),
			older: Type.Optional(Type.Integer({ minimum: 0 })),
			newer: Type.Optional(Type.Integer({ minimum: 0 })),
			part: Type.Optional(Type.Integer({ minimum: 0, description: "With older: 0, newer: 0: only this part of the entry" })),
			offset: Type.Optional(Type.Integer({ minimum: 1, description: "With older: 0, newer: 0: the line to start at" })),
			truncate: Type.Optional(Type.Boolean({ description: "false: every part whole" })),
		}),
		structuredOutputSchema: Type.Unknown(),
		replay: "safe",
		execute: async (args, api, context: Context) => {
			try {
				const result = await history.read(api.conversationId, args, context);
				return { output: [{ type: "text" as const, text: JSON.stringify(result) }], structuredOutput: result as never };
			} catch (error) {
				if (!(error instanceof HistoryError)) throw error;
				return { output: [{ type: "text" as const, text: error.message }], isError: true };
			}
		},
	});
	return defineExtension({ name: "history", tools: [read] });
}

/** The model's call of a running tool: its entry, so a search of `this` leaves out the call itself. */
export function callingEntry(entries: readonly EntryRecord[], callId: string): EntryRecord | undefined {
	const id = modelCallId(callId);
	return entries.find((entry) => toolCalls(entry).some((call) => call.id === id));
}
