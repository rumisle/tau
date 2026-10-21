// One client connection: request dispatch, conversation subscriptions, and pushes. See docs/protocol.md.
import type { Context, JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT, withCancel } from "@earendil-works/chord/context";
import type { Op } from "@earendil-works/chord/delta";
import type { ImageContent, ModelThinkingLevel, TextContent } from "@earendil-works/pi-ai";
import {
	type AgentChange,
	type Conversation,
	ConversationBusy,
	type ConversationId,
	type ConversationWatch,
	type Cursor,
	type EntryId,
	type EntryRecord,
	type SubmissionId,
} from "@earendil-works/pi-durable";
import { readFileSync } from "node:fs";
import { homedir, hostname } from "node:os";
import type { Dialogs } from "./dialogs.ts";
import { directory, listDirectory } from "./fs.ts";
import { CreatesDoc, type Host, MetaDoc } from "./host.ts";
import {
	type AgentPatch,
	type ErrorCode,
	int,
	limit,
	obj,
	PROTOCOL_VERSION,
	ProtocolError,
	type Request,
	str,
} from "./protocol.ts";

/** Pause pushes while this much is unsent; the watch then coalesces, and a far-behind client gets a resync. */
const HIGH_WATER_BYTES = 4 * 1024 * 1024;
const TITLE_CHARS = 60;

// What one message may carry. Anthropic takes images of up to 5 MB; larger content is refused at admission, where the
// sender sees it as not sent, rather than failing the run after the message is in the transcript.
const MAX_TEXT_CHARS = 1_000_000;
const MAX_IMAGES = 20;
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"]);
/** Tombstones kept per conversation; a withdrawn submit arrives within seconds, if ever. */
const MAX_WITHDRAWN = 100;
const MAX_CREATES = 200;

/** Requests that change a conversation run one at a time per conversation, in arrival order (src/serial.ts). */
const SERIAL_METHODS = new Set([
	"conversation.submit",
	"submission.withdraw",
	"submission.abort",
	"conversation.abort",
	"conversation.reset",
	"conversation.compact",
	"conversation.configure",
]);

/** What a connection needs from its socket. */
export interface Socket {
	send(data: string): void;
	readonly bufferedAmount: number;
	close(code?: number, reason?: string): void;
}

type Subscription = {
	readonly watch: ConversationWatch;
	/** Newest entry ID sent; later frames only add newer ones. */
	maxSent: number;
	/** Set once the subscribe response is out; submission pushes start then. */
	live: boolean;
};


/** The pi commit the server links (PI_REVISION at the repository root), reported in `hello`. */
const PI_REVISION = (() => {
	try {
		return readFileSync(new URL("../../PI_REVISION", import.meta.url), "utf-8").trim();
	} catch {
		return "";
	}
})();

export class Connection {
	readonly #host: Host;
	readonly #dialogs: Dialogs;
	readonly #socket: Socket;
	readonly #context: Context;
	readonly #cancel: () => void;
	readonly #subscriptions = new Map<ConversationId, Subscription>();
	readonly #cleanups: (() => void)[] = [];
	#stopDialogs: (() => void) | undefined;
	#hello = false;
	#closed = false;

	constructor(host: Host, dialogs: Dialogs, socket: Socket) {
		this.#host = host;
		this.#dialogs = dialogs;
		this.#socket = socket;
		const { context, cancel } = withCancel(BACKGROUND_CONTEXT);
		this.#context = context;
		this.#cancel = () => cancel(new Error("connection closed"));
		this.#cleanups.push(
			dialogs.onSubmission((record) => {
				// Every conversation's, once the chat list is subscribed: a client learns what became of a message it
				// sent even with that chat closed.
				if (this.#stopDialogs !== undefined || this.#subscriptions.get(record.conversationId)?.live) {
					this.#push({ event: "submission", record });
				}
			}),
		);
	}

	/** Handle one text frame. Never throws. */
	async receive(data: string): Promise<void> {
		let request: Request;
		try {
			request = JSON.parse(data) as Request;
			if (typeof request !== "object" || request === null || typeof request.method !== "string") {
				throw new Error("not a request");
			}
		} catch {
			this.#push({ id: null, error: { code: "bad_request", message: "Malformed request" } });
			return;
		}
		try {
			const params = request.params ?? {};
			if (request.method === "conversation.subscribe") {
				if (!this.#hello) throw new ProtocolError("bad_request", "Send hello first");
				const { id, subscription, result } = await this.#subscribe(params);
				this.#push({ id: request.id, result });
				// A subscription's frames may only follow its response.
				this.#start(id, subscription);
				return;
			}
			const method = request.method;
			let result: Promise<unknown>;
			if (SERIAL_METHODS.has(method) && typeof params.conversationId === "number") {
				// Queued now, before any await, so this socket's requests keep their order.
				result = this.#host.serial.run(`conversation:${params.conversationId}`, () => this.#dispatch(method, params));
			} else if (method === "conversation.create" || method === "conversation.fork") {
				result = this.#host.serial.run("create", () => this.#dispatch(method, params));
			} else result = this.#dispatch(method, params);
			this.#push({ id: request.id, result: await result });
		} catch (error) {
			const { code, message } = describe(error);
			if (code === "internal") console.error(`[tau] ${request.method} failed:`, error);
			this.#push({ id: request.id, error: { code, message } });
		}
	}

	async close(): Promise<void> {
		if (this.#closed) return;
		this.#closed = true;
		this.#cancel();
		for (const cleanup of this.#cleanups) cleanup();
		this.#stopDialogs?.();
		const watches = [...this.#subscriptions.values()].map((subscription) => subscription.watch.stop());
		this.#subscriptions.clear();
		await Promise.allSettled(watches);
	}

	async #dispatch(method: string, params: Record<string, unknown>): Promise<unknown> {
		if (method === "hello") return this.#helloRequest(params);
		if (!this.#hello) throw new ProtocolError("bad_request", "Send hello first");
		const context = this.#context;
		const { harness } = this.#host;
		switch (method) {
			case "models.list":
				return this.#models();
			case "settings.configure": {
				const model = obj(params, "defaultModel");
				if (model !== undefined) {
					await this.#host.setDefaultModel({ provider: str(model, "provider"), modelId: str(model, "modelId") });
				}
				return { defaultModel: this.#host.defaultModel };
			}
			case "fs.list": {
				const hidden = params.hidden;
				if (hidden !== undefined && typeof hidden !== "boolean") {
					throw new ProtocolError("bad_request", "hidden must be a boolean");
				}
				return listDirectory(str(params, "path", true) ?? homedir(), { hidden: hidden === true });
			}
			case "dialogs.subscribe":
				this.#stopDialogs ??= this.#dialogs.onDialog((dialog) => this.#push({ event: "dialog", dialog }));
				return { dialogs: await this.#dialogs.list(context) };
			case "conversation.create": {
				const requestId = str(params, "requestId", true);
				if (requestId !== undefined) {
					const existing = (await harness.snapshot(CreatesDoc, context))?.requests[requestId];
					if (existing !== undefined) return { dialog: await this.#dialogOf(existing as ConversationId) };
				}
				const title = str(params, "title", true);
				const autoTitle = params.autoTitle === true;
				const patch = obj(params, "agent") ?? {};
				const conversation = await harness.createConversation(
					{
						ownership: { kind: "ownerless" },
						agent: await agentChange({ model: this.#host.defaultModel, ...patch }),
						init: async (tx, id) => {
							const meta = await tx.doc(MetaDoc, id);
							if (title !== undefined) meta.title = title;
							if (autoTitle) meta.autoTitle = true;
							if (requestId !== undefined) {
								const creates = await tx.doc(CreatesDoc);
								creates.requests[requestId] = id;
								creates.order.push(requestId);
								while (creates.order.length > MAX_CREATES) delete creates.requests[creates.order.shift()!];
							}
						},
					},
					context,
				);
				return { dialog: await this.#dialogOf(conversation.id) };
			}
			case "conversation.fork": {
				const conversation = await this.#conversation(params);
				const title = str(params, "title", true);
				// As for creates: a repeated fork (after a lost response) returns the conversation the first one made.
				const requestId = str(params, "requestId", true);
				if (requestId !== undefined) {
					const existing = (await harness.snapshot(CreatesDoc, context))?.requests[requestId];
					if (existing !== undefined) return { dialog: await this.#dialogOf(existing as ConversationId) };
				}
				const fork = await conversation.fork(
					int(params, "at") as EntryId,
					{
						ownership: { kind: "ownerless" },
						init: async (tx, id) => {
							const meta = await tx.doc(MetaDoc, id);
							if (title !== undefined) meta.title = title;
							// The fork's history was read in the original.
							meta.read = int(params, "at");
							if (requestId !== undefined) {
								const creates = await tx.doc(CreatesDoc);
								creates.requests[requestId] = id;
								creates.order.push(requestId);
								while (creates.order.length > MAX_CREATES) delete creates.requests[creates.order.shift()!];
							}
						},
					},
					context,
				);
				return { dialog: await this.#dialogOf(fork.id) };
			}
			case "conversation.configure": {
				const conversation = await this.#conversation(params);
				await conversation.configure(await agentChange(obj(params, "agent") ?? {}), context);
				return {};
			}
			case "conversation.rename": {
				const conversation = await this.#conversation(params);
				const title = str(params, "title");
				await conversation.commit(async (tx) => {
					(await tx.doc(MetaDoc, conversation.id)).title = title;
				}, context);
				return {};
			}
			case "conversation.read": {
				const conversation = await this.#conversation(params);
				const at = int(params, "at");
				await conversation.commit(async (tx) => {
					const meta = await tx.doc(MetaDoc, conversation.id);
					if ((meta.read ?? 0) < at) meta.read = at;
					delete meta.markedUnread;
				}, context);
				return {};
			}
			case "conversation.mark": {
				const conversation = await this.#conversation(params);
				const latest = (await conversation.entries({}, 1, undefined, context)).items[0]?.id;
				await conversation.commit(async (tx) => {
					const meta = await tx.doc(MetaDoc, conversation.id);
					if (params.unread === true) meta.markedUnread = true;
					else if (params.unread === false) {
						delete meta.markedUnread;
						if (latest !== undefined) meta.read = latest;
					}
					if (params.archived === true) meta.archived = true;
					else if (params.archived === false) delete meta.archived;
				}, context);
				return {};
			}
			case "conversation.unsubscribe": {
				const id = int(params, "conversationId") as ConversationId;
				const subscription = this.#subscriptions.get(id);
				this.#subscriptions.delete(id);
				await subscription?.watch.stop();
				return {};
			}
			case "conversation.history":
				return this.#history(params);
			case "conversation.submit":
				return this.#submit(params);
			case "submission.withdraw":
				return this.#withdraw(params);
			case "submission.abort": {
				const conversationId = int(params, "conversationId") as ConversationId;
				const id = int(params, "submissionId") as SubmissionId;
				return { result: await harness.abortSubmission(id, context, conversationId) };
			}
			case "conversation.abort": {
				const conversation = await this.#conversation(params);
				await conversation.abort(context);
				return {};
			}
			case "conversation.compact": {
				const conversation = await this.#conversation(params);
				return { taskId: await conversation.compact(str(params, "instructions", true), context) };
			}
			case "conversation.reset": {
				const conversation = await this.#conversation(params);
				await conversation.reset(str(params, "handoff", true), context);
				return {};
			}
			default:
				throw new ProtocolError("bad_request", `Unknown method ${method}`);
		}
	}

	#helloRequest(params: Record<string, unknown>): unknown {
		const protocol = int(params, "protocol");
		if (protocol !== PROTOCOL_VERSION) {
			throw new ProtocolError("bad_request", `Unsupported protocol ${protocol}; server speaks ${PROTOCOL_VERSION}`);
		}
		this.#hello = true;
		return {
			protocol: PROTOCOL_VERSION,
			serverId: this.#host.serverId,
			defaultModel: this.#host.defaultModel,
			defaultCwd: this.#host.cwd,
			home: homedir(),
			hostname: hostname(),
			piRevision: PI_REVISION,
			uptime: Math.round(process.uptime()),
		};
	}

	async #models(): Promise<unknown> {
		const available = await this.#host.models.getAvailable();
		return {
			models: available.map((model) => ({
				provider: model.provider,
				id: model.id,
				name: model.name,
				reasoning: model.reasoning,
				contextWindow: model.contextWindow,
				input: model.input,
			})),
		};
	}

	async #conversation(params: Record<string, unknown>): Promise<Conversation> {
		const id = int(params, "conversationId") as ConversationId;
		const conversation = await this.#host.harness.conversation(id, this.#context);
		if (conversation === undefined) throw new ProtocolError("not_found", `Conversation ${id} does not exist`);
		return conversation;
	}

	async #dialogOf(id: ConversationId): Promise<unknown> {
		const record = await this.#host.storage.conversation(id, this.#context);
		if (record === undefined) throw new ProtocolError("not_found", `Conversation ${id} does not exist`);
		return this.#dialogs.dialog(record, this.#context);
	}

	async #subscribe(
		params: Record<string, unknown>,
	): Promise<{ id: ConversationId; subscription: Subscription; result: unknown }> {
		const conversation = await this.#conversation(params);
		const after = int(params, "after", true);
		const max = limit(params);
		const previous = this.#subscriptions.get(conversation.id);
		this.#subscriptions.delete(conversation.id);
		await previous?.watch.stop();

		// Attach first: every commit after this point arrives as a frame, every commit before it is in storage. An entry
		// in both is sent twice, which clients absorb by upserting by ID.
		const watch = await conversation.watch(this.#context);
		try {
			let entries: EntryRecord[];
			let hasOlder = false;
			let gap: { after: number; before: number } | undefined;
			if (after === undefined) {
				const page = await conversation.entries({ order: "descending" }, max, undefined, this.#context);
				entries = [...page.items].reverse();
				hasOlder = page.next !== undefined;
			} else {
				const page = await conversation.entries(
					{ minEntryId: (after + 1) as EntryId, order: "ascending" },
					max + 1,
					undefined,
					this.#context,
				);
				if (page.items.length <= max) entries = [...page.items];
				else {
					const tail = await conversation.entries(
						{ minEntryId: (after + 1) as EntryId, order: "descending" },
						max,
						undefined,
						this.#context,
					);
					entries = [...tail.items].reverse();
					gap = { after, before: entries[0]!.id };
				}
			}
			const subscription: Subscription = {
				watch,
				maxSent: Math.max(after ?? 0, entries.at(-1)?.id ?? 0),
				live: false,
			};
			if (this.#closed) throw new ProtocolError("bad_request", "Connection closed");
			// A concurrent subscribe of the same conversation may have set one meanwhile; the last one wins.
			const replaced = this.#subscriptions.get(conversation.id);
			this.#subscriptions.set(conversation.id, subscription);
			if (replaced !== undefined) void replaced.watch.stop();
			const view = watch.value;
			const record = view.conversation;
			const head = view.entries[0]?.head;
			const submissions = (await this.#host.harness.inspect(this.#context)).submissions.filter(
				(submission) => submission.conversationId === conversation.id,
			);
			const result = {
				conversation: record,
				docs: view.docs,
				entries,
				...(head === undefined ? {} : { head }),
				hasOlder,
				...(gap === undefined ? {} : { gap }),
				submissions,
			};
			return { id: conversation.id, subscription, result };
		} catch (error) {
			if (this.#subscriptions.get(conversation.id)?.watch === watch) this.#subscriptions.delete(conversation.id);
			await watch.stop();
			throw error;
		}
	}

	#start(id: ConversationId, subscription: Subscription): void {
		// Replaced by a later subscribe of the same conversation while this one was answering.
		if (this.#subscriptions.get(id) !== subscription || subscription.live) return;
		subscription.live = true;
		subscription.watch.start(async (value, ops) => {
			if (this.#subscriptions.get(id) !== subscription) return;
			await this.#drained();
			if (ops.length === 1 && ops[0]![0] === "r") {
				// The watch fell more than 100 frames behind and coalesced: fetch the entries missed, then replace docs.
				const entries = await this.#missed(id, subscription);
				const head = value.entries[0]?.head;
				this.#push({
					event: "conv.commit",
					conversationId: id,
					docs: value.docs,
					...(entries.length === 0 ? {} : { entries }),
					...(head === undefined ? {} : { head }),
				});
				return;
			}
			const docOps: Op[] = [];
			const entries: EntryRecord[] = [];
			let head: EntryId | undefined;
			for (const op of ops) {
				if (op[0] === "r") continue;
				const path = op[1];
				if (path[0] === "docs") docOps.push(relative(op));
				else if (path[0] === "entries" && op[0] === "p") {
					for (const item of op[4] as unknown as EntryRecord[]) {
						if (item.id > subscription.maxSent) entries.push(item);
						if (item.head !== undefined) head = item.head;
					}
				}
			}
			if (docOps.length === 0 && entries.length === 0 && head === undefined) return;
			if (entries.length > 0) subscription.maxSent = Math.max(subscription.maxSent, entries.at(-1)!.id);
			// One frame per commit, so a client never sees a run end before the answer that ended it.
			this.#push({
				event: "conv.commit",
				conversationId: id,
				...(docOps.length === 0 ? {} : { ops: docOps }),
				...(entries.length === 0 ? {} : { entries }),
				...(head === undefined ? {} : { head }),
			});
		});
	}

	/** Every entry newer than the newest sent, for a resync. */
	async #missed(id: ConversationId, subscription: Subscription): Promise<EntryRecord[]> {
		const conversation = await this.#host.harness.conversation(id, this.#context);
		if (conversation === undefined) return [];
		const missed: EntryRecord[] = [];
		let cursor: Cursor | undefined;
		do {
			const page = await conversation.entries(
				{ minEntryId: (subscription.maxSent + 1) as EntryId, order: "ascending" },
				500,
				cursor,
				this.#context,
			);
			missed.push(...page.items);
			cursor = page.next;
		} while (cursor !== undefined);
		if (missed.length > 0) subscription.maxSent = missed.at(-1)!.id;
		return missed;
	}

	async #history(params: Record<string, unknown>): Promise<unknown> {
		const conversation = await this.#conversation(params);
		const before = int(params, "before");
		const after = int(params, "after", true);
		const page = await conversation.entries(
			{
				maxEntryId: (before - 1) as EntryId,
				...(after === undefined ? {} : { minEntryId: (after + 1) as EntryId }),
				order: "descending",
			},
			limit(params),
			undefined,
			this.#context,
		);
		return { entries: [...page.items].reverse(), hasOlder: page.next !== undefined };
	}

	async #submit(params: Record<string, unknown>): Promise<unknown> {
		const conversation = await this.#conversation(params);
		const requestId = str(params, "requestId");
		if (requestId === "") throw new ProtocolError("bad_request", "requestId must not be empty");
		const content = userContent(params.content);
		const whenBusy = str(params, "whenBusy", true) ?? "followUp";
		if (whenBusy !== "steer" && whenBusy !== "followUp" && whenBusy !== "reject") {
			throw new ProtocolError("bad_request", "whenBusy must be steer, followUp, or reject");
		}
		const { harness } = this.#host;
		const meta = await harness.snapshot(MetaDoc, conversation.id, this.#context);
		if (meta?.withdrawn?.includes(requestId)) {
			throw new ProtocolError("withdrawn", `Request ${requestId} was withdrawn`);
		}
		await this.#checkContent(conversation, content);
		if (meta?.title === undefined) {
			const title = titleFrom(content);
			if (title !== "") {
				await conversation.commit(async (tx) => {
					(await tx.doc(MetaDoc, conversation.id)).title ??= title;
				}, this.#context);
			}
		}
		const submission = await conversation.submit({ type: "input", content, whenBusy, requestId }, this.#context);
		return { submission: await submission.status(this.#context) };
	}

	/**
	 * Withdraw a message by its request ID, whether or not its submit has arrived: a queued one leaves the inbox, and
	 * an unknown ID is remembered so its submit is refused if it arrives later. Runs in the conversation's order
	 * (SERIAL_METHODS), so no submit of the conversation is half done meanwhile.
	 */
	async #withdraw(params: Record<string, unknown>): Promise<unknown> {
		const conversation = await this.#conversation(params);
		const requestId = str(params, "requestId");
		const context = this.#context;
		const existing = await conversation.commit(async (tx) => {
			const record = await tx.submissionByRequest(conversation.id, requestId);
			if (record !== undefined) return record;
			const meta = await tx.doc(MetaDoc, conversation.id);
			// A draft copies what is assigned to it: push through the draft, not the array assigned.
			meta.withdrawn ??= [];
			if (!meta.withdrawn.includes(requestId)) meta.withdrawn.push(requestId);
			while (meta.withdrawn.length > MAX_WITHDRAWN) meta.withdrawn.shift();
			return undefined;
		}, context);
		if (existing === undefined) return { result: "withdrawn" };
		const result = await this.#host.harness.abortSubmission(existing.id, context, conversation.id);
		const submission = await (await this.#host.harness.submission(existing.id, context))?.status(context);
		return { result, ...(submission === undefined ? {} : { submission }) };
	}

	/** Refuse content the conversation's model cannot take, before it is admitted. */
	async #checkContent(conversation: Conversation, content: string | (TextContent | ImageContent)[]): Promise<void> {
		const parts = typeof content === "string" ? [{ type: "text" as const, text: content }] : content;
		let text = 0;
		let images = 0;
		for (const part of parts) {
			if (part.type === "text") text += part.text.length;
			else {
				images += 1;
				if (!IMAGE_TYPES.has(part.mimeType)) {
					throw new ProtocolError("unsupported", `Images must be JPEG, PNG, GIF or WebP, not ${part.mimeType}`);
				}
				if (Math.floor((part.data.length * 3) / 4) > MAX_IMAGE_BYTES) {
					throw new ProtocolError("too_large", "An image is larger than 5 MB");
				}
			}
		}
		if (text > MAX_TEXT_CHARS) throw new ProtocolError("too_large", "The message is longer than 1,000,000 characters");
		if (images > MAX_IMAGES) throw new ProtocolError("too_large", `A message can carry at most ${MAX_IMAGES} images`);
		if (images === 0) return;
		const ref = (await conversation.agent(this.#context)).model;
		if (ref === undefined) return;
		const model = (await this.#host.models.getAvailable()).find(
			(candidate) => candidate.provider === ref.provider && candidate.id === ref.modelId,
		);
		if (model !== undefined && !model.input.includes("image")) {
			throw new ProtocolError("unsupported", `${model.name} does not take images`);
		}
	}

	#push(message: unknown): void {
		if (this.#closed) return;
		this.#socket.send(JSON.stringify(message));
	}

	async #drained(): Promise<void> {
		while (!this.#closed && this.#socket.bufferedAmount > HIGH_WATER_BYTES) {
			await new Promise((resolve) => setTimeout(resolve, 20));
		}
	}
}

/** A view op under `docs`, made relative to the docs object. */
function relative(op: Op): Op {
	switch (op[0]) {
		case "r":
			return op;
		case "s":
			return ["s", tail(op[1]), op[2]];
		case "d":
			return ["d", tail(op[1])];
		case "a":
			return ["a", tail(op[1]), op[2]];
		case "t":
			return ["t", tail(op[1]), op[2]];
		case "p":
			return ["p", op[1].slice(1), op[2], op[3], op[4]];
		case "m":
			return ["m", op[1].slice(1), op[2]];
	}
}

function tail<P extends readonly (string | number)[]>(path: P): [string | number, ...(string | number)[]] {
	return path.slice(1) as [string | number, ...(string | number)[]];
}

/** A client agent patch as an AgentChange; a `cwd` must name an existing directory and is stored absolute. */
async function agentChange(patch: Record<string, unknown> & AgentPatch): Promise<AgentChange> {
	const change: {
		model?: AgentChange["model"];
		thinkingLevel?: AgentChange["thinkingLevel"];
		instructions?: AgentChange["instructions"];
		cwd?: AgentChange["cwd"];
	} = {};
	if (patch.model !== undefined) {
		const model = patch.model as unknown;
		if (model === null) change.model = null;
		else if (
			typeof model === "object" &&
			typeof (model as AgentPatch["model"] & object).provider === "string" &&
			typeof (model as AgentPatch["model"] & object).modelId === "string"
		) {
			const { provider, modelId } = model as { provider: string; modelId: string };
			change.model = { provider, modelId };
		} else throw new ProtocolError("bad_request", "agent.model must be { provider, modelId } or null");
	}
	if (patch.thinkingLevel !== undefined) {
		if (patch.thinkingLevel !== null && typeof patch.thinkingLevel !== "string") {
			throw new ProtocolError("bad_request", "agent.thinkingLevel must be a string or null");
		}
		change.thinkingLevel = patch.thinkingLevel as ModelThinkingLevel | null;
	}
	for (const key of ["instructions", "cwd"] as const) {
		const value = patch[key];
		if (value === undefined) continue;
		if (value !== null && typeof value !== "string") {
			throw new ProtocolError("bad_request", `agent.${key} must be a string or null`);
		}
		change[key] = key === "cwd" && value !== null ? await directory(value) : value;
	}
	return change;
}

function userContent(value: unknown): string | (TextContent | ImageContent)[] {
	if (typeof value === "string") {
		if (value.trim() === "") throw new ProtocolError("bad_request", "content must not be empty");
		return value;
	}
	if (!Array.isArray(value) || value.length === 0) {
		throw new ProtocolError("bad_request", "content must be a string or a non-empty array of content blocks");
	}
	return value.map((part: unknown) => {
		const block = part as Record<string, JsonValue>;
		if (block?.type === "text" && typeof block.text === "string") return { type: "text", text: block.text };
		if (block?.type === "image" && typeof block.data === "string" && typeof block.mimeType === "string") {
			return { type: "image", data: block.data, mimeType: block.mimeType };
		}
		throw new ProtocolError("bad_request", "content blocks must be { type: text, text } or { type: image, data, mimeType }");
	});
}

function titleFrom(content: string | (TextContent | ImageContent)[]): string {
	const text =
		typeof content === "string"
			? content
			: content
					.filter((part) => part.type === "text")
					.map((part) => part.text)
					.join(" ");
	const line = text.trim().split("\n")[0]!.trim();
	return line.length <= TITLE_CHARS ? line : `${line.slice(0, TITLE_CHARS - 1)}…`;
}

function describe(error: unknown): { code: ErrorCode; message: string } {
	if (error instanceof ProtocolError) return { code: error.code, message: error.message };
	if (error instanceof ConversationBusy) return { code: "busy", message: error.message };
	const message = error instanceof Error ? error.message : String(error);
	if (error instanceof Error && error.name === "StorageRequestError") return { code: "not_found", message };
	return { code: "internal", message };
}
