// Edits as versions in one conversation (docs/edits-and-forks.md). An edit of a user message goes back to before it
// and goes on from the new text, in the same conversation: an entry with durable's context edits omits the message and
// everything after it from what the model sees, and the new text is the next input. Nothing is deleted: the versions
// of a message are kept in `tau.versions`, and a switch to another one omits the current version's entries and gives
// the other's back their own messages (a `replace` with an entry's own messages is the entry as it was).
//
// What clients hide is `hidden`: ranges of entry IDs whose entries belong to versions not shown. A version's entries
// are those from its message to where it was left, less what was hidden then, so a range never needs the
// conversation's IDs to be contiguous.
import type { Context } from "@earendil-works/chord/context";
import type { AssistantMessage, UserMessage } from "@earendil-works/pi-ai";
import {
	type Conversation,
	type ConversationId,
	type ContextEdit,
	defineDoc,
	type EntryId,
	type EntryRecord,
	LiveDoc,
	type Tx,
} from "@earendil-works/pi-durable";
import { summarize } from "./dialogs.ts";

/** An inclusive range of entry IDs. */
export type Span = [number, number];

export type Version = {
	/** The version's user message. */
	message: number;
	/** When it was made, epoch ms. */
	at: number;
	/** Its message, as the chat list previews one. */
	text: string;
	/** Its entries when it was left; absent while it is the current one. */
	spans?: Span[];
	/** The first line of its last answer, and what its answers cost, when it was left. */
	answer?: string;
	cost?: number;
};

export type VersionGroup = { versions: Version[]; current: number };

export type VersionsState = {
	/** By the first version's message. */
	groups: Record<string, VersionGroup>;
	/** Entries of versions not shown, sorted and disjoint. */
	hidden: Span[];
};

/** Rewindable, so a fork has the versions as they were at its fork entry: later edits are not in its history. */
export const VersionsDoc = defineDoc<VersionsState>({
	kind: "tau.versions",
	version: 1,
	scope: "conversation",
	history: "rewindable",
	fork: "asOf",
	initial: () => ({ groups: {}, hidden: [] }),
	checkpointWhen: () => true,
});

/** The entry an edit appends: its context edits, and which message got which new version. Clients show none. */
export const EDIT_KIND = "tau.edit";
/** The entry a switch to another version appends. */
export const VERSION_KIND = "tau.version";

export function hiddenIn(spans: readonly Span[], id: number): boolean {
	let low = 0;
	let high = spans.length - 1;
	while (low <= high) {
		const middle = (low + high) >>> 1;
		const [from, to] = spans[middle]!;
		if (id < from) high = middle - 1;
		else if (id > to) low = middle + 1;
		else return true;
	}
	return false;
}

/** `a` with `b`'s ranges added: sorted, disjoint, adjacent ranges joined. */
export function union(a: readonly Span[], b: readonly Span[]): Span[] {
	const all = [...a, ...b].map(([from, to]) => [from, to] as Span).sort((x, y) => x[0] - y[0]);
	const out: Span[] = [];
	for (const span of all) {
		const last = out.at(-1);
		if (last !== undefined && span[0] <= last[1] + 1) last[1] = Math.max(last[1], span[1]);
		else out.push(span);
	}
	return out;
}

/** `a` less `b`'s ranges. */
export function subtract(a: readonly Span[], b: readonly Span[]): Span[] {
	let out: Span[] = a.map(([from, to]) => [from, to]);
	for (const [from, to] of b) {
		out = out.flatMap(([x, y]): Span[] => {
			if (to < x || from > y) return [[x, y]];
			const kept: Span[] = [];
			if (from > x) kept.push([x, from - 1]);
			if (to < y) kept.push([to + 1, y]);
			return kept;
		});
	}
	return out;
}

/** Why an edit or a switch can't go in place; the caller forks instead or says so. */
export class VersionError extends Error {
	readonly code: "before_summary" | "not_found" | "busy";
	constructor(code: "before_summary" | "not_found" | "busy", message: string) {
		super(message);
		this.code = code;
	}
}

/** Every entry visible from the conversation from `from` on, oldest first. Table reads: before a commit's writes. */
async function entriesFrom(tx: Tx, conversationId: ConversationId, from: number): Promise<EntryRecord[]> {
	const entries: EntryRecord[] = [];
	let cursor: Parameters<Tx["scanEntries"]>[2];
	do {
		const page = await tx.scanEntries({ conversationId, minEntryId: from as EntryId, order: "ascending" }, 500, cursor);
		entries.push(...page.items);
		cursor = page.next;
	} while (cursor !== undefined);
	return entries;
}

/**
 * Whether an entry is what the model reads: one with messages, not a head marker (a compaction's summary covers what
 * came before the edit too) and not `pi.system` (sections and tools, which generation keeps as it finds them).
 */
function readByModel(entry: EntryRecord): boolean {
	return entry.model !== undefined && entry.model.length > 0 && entry.head === undefined && entry.kind !== "pi.system";
}

function costOf(entries: readonly EntryRecord[]): number {
	let total = 0;
	for (const entry of entries) {
		const message = entry.model?.[0] as AssistantMessage | undefined;
		if (message?.role === "assistant") total += message.usage?.cost?.total ?? 0;
	}
	return total;
}

/** The first line of the last answer with text, as the Versions menu shows it under the version's message. */
function lastAnswer(entries: readonly EntryRecord[]): string | undefined {
	for (let index = entries.length - 1; index >= 0; index--) {
		const message = entries[index]!.model?.[0] as AssistantMessage | undefined;
		if (message?.role !== "assistant") continue;
		const text = message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
		const line = text.split("\n").map((each) => each.trim()).find((each) => each !== "");
		if (line !== undefined) return line.length <= 200 ? line : `${line.slice(0, 199)}…`;
	}
	return undefined;
}

/** The version of `group` whose message is `message`, and the group's key. */
function findVersion(state: VersionsState, message: number): { key: string; index: number } | undefined {
	for (const [key, group] of Object.entries(state.groups)) {
		const index = group.versions.findIndex((version) => version.message === message);
		if (index !== -1) return { key, index };
	}
	return undefined;
}

/** The start of the model's active context: the newest head marker's `head`. */
async function activeStart(tx: Tx, conversationId: ConversationId): Promise<number | undefined> {
	return (await tx.latestHeadMarker(conversationId))?.head;
}

/** Stops a run and what is queued, so an edit or a switch has the conversation to itself. */
async function idle(conversation: Conversation, context: Context): Promise<void> {
	await conversation.abort(context);
}

export type EditInput = { message: number; content: UserMessage["content"]; requestId: string };

/**
 * An edit in place: `message` (a user message the chat shows) gets a new version with `content`, which starts a run.
 * A running answer is stopped first. Repeated with the same request ID (after a lost response), it does nothing more.
 * Throws `VersionError` "before_summary" when the message is older than the active context's start: the context can't
 * go back there, so the caller forks before it instead.
 */
export async function editInPlace(conversation: Conversation, input: EditInput, now: () => number, context: Context): Promise<void> {
	const id = conversation.id;
	for (let attempt = 0; attempt < 5; attempt++) {
		// Also what a failed run left queued: the edit replaces the turn it was for.
		await idle(conversation, context);
		const done = await conversation.commit(async (tx) => {
			// Tables first: a commit reads none after its first write.
			if ((await tx.submissionByRequest(id, input.requestId)) !== undefined) return true;
			const live = await tx.doc(LiveDoc, id);
			if (live.run !== undefined) return false;
			const start = await activeStart(tx, id);
			if (start !== undefined && input.message < start) throw new VersionError("before_summary", "The message is older than the context's summary");
			const state = await tx.doc(VersionsDoc, id);
			if (hiddenIn(state.hidden, input.message)) throw new VersionError("not_found", "The message is in a version not shown");
			const entries = await entriesFrom(tx, id, input.message);
			const target = entries[0];
			if (target?.id !== input.message || target.model?.[0]?.role !== "user") throw new VersionError("not_found", `Entry ${input.message} is not a user message of this chat`);
			const shown = entries.filter((entry) => !hiddenIn(state.hidden, entry.id));
			const tail = entries.at(-1)!.id;

			await conversation.submit(tx, { type: "input", content: input.content, whenBusy: "followUp", requestId: input.requestId });
			// Placed at once (the conversation is idle and nothing is queued): the run's first entry is the new message.
			const placed = (await tx.doc(LiveDoc, id)).run?.first;
			const edits: ContextEdit[] = shown.filter(readByModel).map((entry) => ({ target: entry.id, action: "omit" }));
			await tx.appendEntry(id, { kind: EDIT_KIND, data: { message: input.message, version: placed ?? null }, edits });

			const spans = subtract([[input.message, tail]], state.hidden);
			const found = findVersion(state, input.message);
			const key = found?.key ?? String(input.message);
			// Set, then read back: the draft keeps a copy of what is set, not the object.
			if (found === undefined) state.groups[key] = { versions: [{ message: input.message, at: (target.model[0] as UserMessage).timestamp ?? now(), text: summarize(target).text }], current: 0 };
			const group = state.groups[key]!;
			const left = group.versions[group.current]!;
			left.spans = spans;
			const answer = lastAnswer(shown);
			if (answer === undefined) delete left.answer;
			else left.answer = answer;
			left.cost = costOf(shown);
			if (placed !== undefined) {
				const preview = summarize({ id: placed, conversationId: id, kind: "pi.user", model: [{ role: "user", content: input.content, timestamp: now() }] } as unknown as EntryRecord).text;
				group.versions.push({ message: placed, at: now(), text: preview });
				group.current = group.versions.length - 1;
			}
			state.hidden = union(state.hidden, spans);
			return true;
		}, context);
		if (done) return;
	}
	throw new VersionError("busy", "The chat kept working: try again");
}

/**
 * Shows another version of a message: `message` is that version's message. The current version's entries are omitted
 * and the other's given their own messages back. Throws "before_summary" when either reaches before the active
 * context's start, which a switch in place can't bring back: the caller forks at the version's last entry instead.
 * Returns that entry for it.
 */
export async function switchVersion(conversation: Conversation, message: number, context: Context): Promise<void> {
	const id = conversation.id;
	for (let attempt = 0; attempt < 5; attempt++) {
		await idle(conversation, context);
		const done = await conversation.commit(async (tx) => {
			const live = await tx.doc(LiveDoc, id);
			if (live.run !== undefined) return false;
			const state = await tx.doc(VersionsDoc, id);
			const found = findVersion(state, message);
			if (found === undefined) throw new VersionError("not_found", `No version with message ${message}`);
			const group = state.groups[found.key]!;
			if (found.index === group.current) return true;
			const target = group.versions[found.index]!;
			const current = group.versions[group.current]!;
			const start = await activeStart(tx, id);
			if (start !== undefined && (current.message < start || (target.spans ?? []).some(([from]) => from < start))) {
				throw new VersionError("before_summary", "The version is older than the context's summary");
			}
			const leaving = (await entriesFrom(tx, id, current.message)).filter((entry) => !hiddenIn(state.hidden, entry.id));
			const back: EntryRecord[] = [];
			for (const [from, to] of target.spans ?? []) {
				let cursor: Parameters<Tx["scanEntries"]>[2];
				do {
					const page = await tx.scanEntries({ conversationId: id, minEntryId: from as EntryId, maxEntryId: to as EntryId, order: "ascending" }, 500, cursor);
					back.push(...page.items);
					cursor = page.next;
				} while (cursor !== undefined);
			}
			const tail = (await tx.latestEntryId(id)) ?? current.message;

			const edits: ContextEdit[] = [
				...leaving.filter(readByModel).map((entry): ContextEdit => ({ target: entry.id, action: "omit" })),
				...back.filter(readByModel).map((entry): ContextEdit => ({ target: entry.id, action: "replace", messages: entry.model! })),
			];
			await tx.appendEntry(id, { kind: VERSION_KIND, data: { message }, edits });

			const spans = subtract([[current.message, tail]], state.hidden);
			current.spans = spans;
			const answer = lastAnswer(leaving);
			if (answer === undefined) delete current.answer;
			else current.answer = answer;
			current.cost = costOf(leaving);
			state.hidden = subtract(union(state.hidden, spans), target.spans ?? []);
			delete target.spans;
			group.current = found.index;
			return true;
		}, context);
		if (done) return;
	}
	throw new VersionError("busy", "The chat kept working: try again");
}

/** The last entry of a version not shown, where a fork shows it as it was. */
export function versionEnd(state: VersionsState, message: number): number | undefined {
	const found = findVersion(state, message);
	if (found === undefined) return undefined;
	return state.groups[found.key]!.versions[found.index]!.spans?.at(-1)?.[1];
}
