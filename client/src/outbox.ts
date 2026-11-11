// What this device sent, from the tap on Send until the server has it in the transcript or refused it
// (docs/sending.md): messages, the creates they wait for, and the requests ordered with them, one at a time per
// conversation, through any number of reconnects. Network failures never fail a message; only the server refusing it.
// Pure: the caller gives it a connection while there is one, keeps its state where it lasts, and shows what it says.
import { RequestError } from "./connection.ts";
import type { JsonObject } from "./protocol.ts";

export type SendMode = "steer" | "followUp";

export type OutgoingState =
	/** Not acknowledged: the submit goes (again) when its turn comes. */
	| { type: "pending" }
	/** In the server's inbox. */
	| { type: "queued"; submissionId: number }
	/** In the transcript; kept until its entry reaches the replica, so its row keeps its place. */
	| { type: "placed"; entryId: number }
	/** Refused for good; the row offers Resend and Delete. */
	| { type: "failed"; code: string; message: string }
	/** Cancelled by the user; the withdraw goes when its turn comes. */
	| { type: "withdrawing" };

/** A photo or file a message carries (docs/files.md): uploaded before the submit, which names it by its ID. */
export type Upload = {
	/** A photo the model also sees; a file it gets as a path. */
	kind: "photo" | "file";
	/** Where the caller keeps its bytes until the message is done with them (beside the outbox). */
	key: string;
	name: string;
	size: number;
	mimeType: string;
	width?: number;
	height?: number;
	/** The server's ID, once uploaded. */
	serverId?: string;
};

export type OutgoingMessage = {
	requestId: string;
	/** Undefined until the draft conversation it starts exists; `createRequestId` names that draft. */
	conversationId?: number;
	createRequestId?: string;
	text: string;
	/** Photos and files, uploaded first, in order. */
	uploads?: Upload[];
	mode: SendMode;
	/** Epoch ms. */
	date: number;
	state: OutgoingState;
	submissionId?: number;
	/** Written to a socket at least once: the server may have it, so cancelling needs a withdraw. */
	wasSent: boolean;
	/** `internal` errors so far: transient up to a point. */
	attempts: number;
	/** Shown in the input field's queue rather than the chat: sent while the agent worked, or queued by the server. */
	showsInQueue: boolean;
	/** Position among its conversation's operations; each runs after every lower one. */
	seq: number;
	/** Put the text back in the input field once withdrawn (Stop, Edit). */
	restoresOnWithdraw?: boolean;
	/** Submitted only once this request ID was withdrawn: the second half of a move. Dropped if that one got through. */
	replaces?: string;
	/** Acknowledged before a reconnect: submitted again (same request ID, no side effect) to learn what became of it. */
	needsRefresh?: boolean;
};

/** A draft conversation being created for the messages sent to it, idempotent through its request ID. */
export type PendingCreate = {
	requestId: string;
	title?: string;
	/** False once the user named it. */
	autoTitle?: boolean;
	/** The agent the draft showed (an AgentPatch). */
	agent?: JsonObject;
	/** A fork of this conversation at this entry, as an edit makes, instead of a new conversation. */
	forkOf?: number;
	forkAt?: number;
	attempts: number;
};

/** What lasts: written before each request goes out. */
export type OutboxState = {
	items: OutgoingMessage[];
	creates: PendingCreate[];
	/** What became of withdrawn request IDs that a replacement waits on: true when the original reached the model. */
	withdrawOutcomes: Record<string, boolean>;
	/** Conversations the creates made, by their request IDs, for drafts that learn of it late. */
	created: Record<string, number>;
	nextSeq: number;
	/** The database the messages were written for: another one's conversation IDs mean other conversations. */
	serverId?: string;
};

export interface Requester {
	request(method: string, params?: Record<string, unknown>): Promise<any>;
}

/** A refusal of an upload: the server answered with this status. Any other error is the network's. */
export class UploadError extends Error {
	readonly status: number;
	constructor(status: number, message: string) {
		super(message);
		this.name = "UploadError";
		this.status = status;
	}
}

export type OutboxEvents = {
	/** A message left the outbox: the caller may drop what it kept for its uploads (keys no other message uses). */
	removed?(item: OutgoingMessage, unusedKeys: string[]): void;
	/** A conversation's messages changed; undefined for the drafts' (those without a conversation yet). */
	changed?(conversationId: number | undefined): void;
	/** A withdrawn text to put back in the conversation's input field. */
	restored?(conversationId: number, text: string): void;
	/** A draft conversation exists now. */
	created?(create: PendingCreate, conversationId: number, dialog: JsonObject): void;
	/** Something to tell the user, as a toast. */
	notice?(conversationId: number, text: string): void;
	/** A message became an entry of its conversation. */
	placed?(item: OutgoingMessage, entryId: number): void;
};

export type OutboxOptions = {
	state?: OutboxState;
	persist?: (state: OutboxState) => Promise<void> | void;
	events?: OutboxEvents;
	newId?: () => string;
	now?: () => number;
	/** Runs `run` after `ms`: the backoff's timer. */
	delay?: (ms: number, run: () => void) => void;
	/** Uploads a message's file: its server ID. Throws an UploadError for a refusal, anything else for the network. */
	upload?: (upload: Upload) => Promise<string>;
};

type Transient = {
	seq: number;
	conversationId?: number;
	createRequestId?: string;
	method: string;
	params: Record<string, unknown>;
	/** Repeated after a lost connection; false for what must not happen twice (a compaction). */
	repeatable: boolean;
	/** Dropped if not sent by then (epoch ms): a Stop that waited out a long disconnection would stop a later run. */
	deadline?: number;
	resolve: (value: any) => void;
	reject: (error: Error) => void;
};

type Operation = { type: "submit"; requestId: string } | { type: "withdraw"; requestId: string } | { type: "transient"; seq: number };

export const MAX_ATTEMPTS = 5;
export const MAX_TEXT = 1_000_000;
export const MAX_UPLOADS = 20;
/** How long a Stop waits for a connection before it no longer means the run it was for. */
export const ABORT_DEADLINE_MS = 20_000;

/** The connection, not the server, failed: the request may or may not have arrived. */
export function isConnectionError(error: unknown): boolean {
	return !(error instanceof RequestError) || error.code === "disconnected" || error.code === "timeout";
}

export function emptyOutboxState(): OutboxState {
	return { items: [], creates: [], withdrawOutcomes: {}, created: {}, nextSeq: 1 };
}

export class Outbox {
	state: OutboxState;
	readonly #persist: (state: OutboxState) => Promise<void> | void;
	readonly #events: OutboxEvents;
	readonly #newId: () => string;
	readonly #now: () => number;
	readonly #delay: (ms: number, run: () => void) => void;
	readonly #upload: ((upload: Upload) => Promise<string>) | undefined;
	#client: Requester | undefined;
	#saved: Promise<void> = Promise.resolve();
	#transients: Transient[] = [];
	/** Keys with a request in flight: `c<id>` per conversation, `create` for creates. */
	readonly #inFlight = new Set<string>();
	/** The create on the wire, which can no longer take changes. */
	#sendingCreate: string | undefined;
	/** Keys waiting out a backoff after an `internal` error. */
	readonly #backoff = new Set<string>();

	constructor(options: OutboxOptions = {}) {
		this.state = options.state ?? emptyOutboxState();
		this.#persist = options.persist ?? (() => undefined);
		this.#events = options.events ?? {};
		this.#newId = options.newId ?? (() => crypto.randomUUID());
		this.#now = options.now ?? Date.now;
		this.#delay = options.delay ?? ((ms, run) => void setTimeout(run, ms));
		this.#upload = options.upload;
		// Placed messages are entries now; what was queued may have moved on meanwhile
		this.state.items = this.state.items.filter((item) => item.state.type !== "placed");
		for (const item of this.state.items) {
			if (item.state.type === "queued") item.needsRefresh = true;
		}
	}

	// MARK: Queries

	get items(): readonly OutgoingMessage[] {
		return this.state.items;
	}

	itemsOf(conversationId: number): OutgoingMessage[] {
		return this.state.items.filter((item) => item.conversationId === conversationId);
	}

	itemsOfCreate(requestId: string): OutgoingMessage[] {
		return this.state.items.filter((item) => item.conversationId === undefined && item.createRequestId === requestId);
	}

	item(requestId: string): OutgoingMessage | undefined {
		return this.state.items.find((item) => item.requestId === requestId);
	}

	create(requestId: string): PendingCreate | undefined {
		return this.state.creates.find((create) => create.requestId === requestId);
	}

	/** Something still has to reach the server. */
	get hasWork(): boolean {
		if (this.#transients.length > 0 || this.state.creates.length > 0) return true;
		return this.state.items.some(
			(item) => item.state.type === "pending" || item.state.type === "withdrawing" || (item.state.type === "queued" && item.needsRefresh),
		);
	}

	/** Resolves once what was written so far is persisted. */
	flushed(): Promise<void> {
		return this.#saved;
	}

	// MARK: The connection

	/**
	 * Connected to the server with this database: messages written for another one fail, what was acknowledged as queued
	 * asks again (a push may have been missed), and everything waiting goes.
	 */
	connected(client: Requester, serverId: string): void {
		this.#client = client;
		if (this.state.serverId !== undefined && this.state.serverId !== serverId) {
			for (const item of this.state.items) {
				if (item.state.type === "failed" || item.state.type === "placed") continue;
				item.state = { type: "failed", code: "server_changed", message: "The server's data was replaced" };
				item.showsInQueue = false;
				item.needsRefresh = false;
			}
			this.state.items = this.state.items.filter((item) => item.state.type !== "placed");
			this.state.creates = [];
			this.state.created = {};
			const dropped = this.#transients;
			this.#transients = [];
			for (const transient of dropped) transient.reject(new RequestError("server_changed", "The server's data was replaced"));
		}
		this.state.serverId = serverId;
		for (const item of this.state.items) {
			if (item.state.type === "queued") item.needsRefresh = true;
		}
		this.#save();
		this.#changedAll();
		this.pump();
	}

	/** The connection is gone: nothing goes until the next one. Requests on it fail as connection errors. */
	disconnected(): void {
		this.#client = undefined;
	}

	// MARK: What the user does

	/** A message to send, to a conversation or to a draft being created (`createRequestId`). */
	enqueue(options: {
		text: string;
		conversationId?: number;
		createRequestId?: string;
		mode?: SendMode;
		showsInQueue?: boolean;
		replaces?: string;
		uploads?: Upload[];
	}): OutgoingMessage {
		const uploads = options.uploads ?? [];
		const refusal =
			options.text.length > MAX_TEXT
				? "The message is longer than 1,000,000 characters"
				: uploads.length > MAX_UPLOADS
					? "A message can carry at most 20 files"
					: undefined;
		const tooLong = refusal !== undefined;
		const item: OutgoingMessage = {
			requestId: this.#newId(),
			conversationId: options.conversationId ?? (options.createRequestId === undefined ? undefined : this.state.created[options.createRequestId]),
			createRequestId: options.createRequestId,
			text: options.text,
			...(uploads.length > 0 && { uploads }),
			mode: options.mode ?? "steer",
			date: this.#now(),
			state: tooLong ? { type: "failed", code: "too_large", message: refusal } : { type: "pending" },
			wasSent: false,
			attempts: 0,
			showsInQueue: !tooLong && Boolean(options.showsInQueue),
			seq: this.#takeSeq(),
			replaces: options.replaces,
		};
		this.state.items.push(item);
		this.#save();
		this.#events.changed?.(item.conversationId);
		this.pump();
		return item;
	}

	/** A draft conversation to create; its messages and requests wait for it. */
	enqueueCreate(create: Omit<PendingCreate, "attempts">): void {
		if (this.create(create.requestId) !== undefined || this.state.created[create.requestId] !== undefined) return;
		this.state.creates.push({ ...create, attempts: 0 });
		this.#save();
		this.pump();
	}

	/** Changes a create while it has not gone out. False once it has: rename or configure the conversation instead. */
	updateCreate(requestId: string, change: Partial<Pick<PendingCreate, "title" | "autoTitle" | "agent">>): boolean {
		const create = this.create(requestId);
		if (create === undefined || this.#sendingCreate === requestId) return false;
		Object.assign(create, change);
		this.#save();
		return true;
	}

	/**
	 * A request in its conversation's order, after every message and request before it; for a draft, sent once it
	 * exists. Resolves with the server's answer; rejects with its refusal, or, not repeatable, a lost connection.
	 */
	request<T = any>(
		method: string,
		target: { conversationId: number } | { createRequestId: string },
		params: Record<string, unknown> = {},
		options: { repeatable?: boolean; deadlineMs?: number } = {},
	): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			let conversationId = "conversationId" in target ? target.conversationId : this.state.created[target.createRequestId];
			this.#transients.push({
				seq: this.#takeSeq(),
				conversationId,
				createRequestId: "createRequestId" in target ? target.createRequestId : undefined,
				method,
				params: conversationId === undefined ? params : { ...params, conversationId },
				repeatable: options.repeatable ?? true,
				deadline: options.deadlineMs === undefined ? undefined : this.#now() + options.deadlineMs,
				resolve,
				reject,
			});
			this.#save();
			this.pump();
		});
	}

	/**
	 * Cancels a message that has not reached the model: at once when the server never saw it, else by a withdraw in
	 * its turn. False when it is past cancelling.
	 */
	withdraw(requestId: string, options: { restore?: boolean } = {}): boolean {
		const result = this.#markWithdrawing(requestId, Boolean(options.restore));
		this.pump();
		return result;
	}

	/** Queues a message again with another mode: withdrawn, then sent anew if the withdraw came first. */
	move(requestId: string, mode: SendMode): void {
		const item = this.item(requestId);
		if (item?.conversationId === undefined || !this.#markWithdrawing(requestId, false)) return;
		this.#appendReplacement(item, item.conversationId, mode, true);
		this.#save();
		this.pump();
	}

	/**
	 * Interrupts the agent, as pi's Escape does: the queued messages `restoring` are withdrawn and come back to the
	 * input field, the run is aborted, and `sendNow`, if given, is sent at once in its place.
	 */
	interrupt(conversationId: number, options: { restoring?: string[]; sendNow?: string } = {}): Promise<unknown> {
		for (const requestId of options.restoring ?? []) {
			if (requestId !== options.sendNow) this.#markWithdrawing(requestId, true);
		}
		const sendNow = options.sendNow === undefined ? undefined : this.item(options.sendNow);
		const replacing = sendNow !== undefined && this.#markWithdrawing(sendNow.requestId, false) ? sendNow : undefined;
		const done = this.request("conversation.abort", { conversationId }, {}, { deadlineMs: ABORT_DEADLINE_MS });
		// The run is over by then: the chat shows it with the clock until it is in the transcript
		if (replacing !== undefined) this.#appendReplacement(replacing, conversationId, "steer", false);
		this.#save();
		this.pump();
		return done;
	}

	/** Drops a failed message, or one that never left the device. False for one the server may have. */
	discard(requestId: string): boolean {
		const index = this.state.items.findIndex((item) => item.requestId === requestId);
		if (index < 0) return false;
		const item = this.state.items[index]!;
		if (item.state.type !== "failed" && item.wasSent) return false;
		this.#remove(index);
		return true;
	}

	// MARK: What the server says

	/** A submission record from a push, a subscribe, or a response. */
	apply(record: JsonObject): void {
		const id = record.id as number | undefined;
		const requestId = record.requestId as string | undefined;
		const item = this.state.items.find(
			(each) => (id !== undefined && each.submissionId === id) || (requestId !== undefined && each.requestId === requestId),
		);
		if (item === undefined) return;
		const entry = record.entry as number | undefined;
		// A withdraw in its turn decides what becomes of a message being cancelled
		if (item.state.type === "withdrawing") {
			if (entry !== undefined) {
				item.submissionId = id;
				this.#reachedModel(item, entry);
			}
			return;
		}
		item.submissionId = id ?? item.submissionId;
		switch (record.status) {
			case "queued":
				// Records can arrive out of order: never back from the transcript to the queue
				if (item.state.type === "placed" || id === undefined) return;
				this.#update(item, (each) => {
					each.state = { type: "queued", submissionId: id };
					each.showsInQueue = true;
					each.needsRefresh = false;
				});
				return;
			case "placed":
			case "done":
				if (entry !== undefined) this.#reachedModel(item, entry);
				return;
			case "unanswered":
				if (entry !== undefined) {
					// In the transcript; the run that had it ended without an answer, which the transcript shows
					this.#reachedModel(item, entry);
				} else {
					// Withdrawn by someone else (a Stop on another device): back to the input, as pi returns queued
					// messages to the editor
					this.#remove(this.state.items.indexOf(item));
					if (item.conversationId !== undefined && item.text !== "") this.#events.restored?.(item.conversationId, item.text);
				}
				return;
		}
	}

	/** Queued messages whose submissions the server no longer lists as unsettled: ask again what became of them. */
	refreshSettled(conversationId: number, unsettled: Set<number>): void {
		let touched = false;
		for (const item of this.itemsOf(conversationId)) {
			if (item.state.type === "queued" && !unsettled.has(item.state.submissionId) && !item.needsRefresh) {
				item.needsRefresh = true;
				touched = true;
			}
		}
		if (!touched) return;
		this.#save();
		this.pump();
	}

	/**
	 * New user entries of a conversation, matched to what is on its way before the records come, so a row goes from the
	 * clock or the queue to the transcript in one step. An entry is the oldest sent message whose text it starts with.
	 */
	matchPlacements(conversationId: number, entries: { id: number; text: string; files?: number }[]): void {
		const used = new Set<string>();
		for (const entry of [...entries].sort((a, b) => a.id - b.id)) {
			if (this.state.items.some((item) => item.state.type === "placed" && item.state.entryId === entry.id)) continue;
			const match = this.state.items
				.filter((item) => item.conversationId === conversationId && item.wasSent && !used.has(item.requestId))
				.filter((item) => item.state.type === "pending" || item.state.type === "queued" || item.state.type === "withdrawing")
				.sort((a, b) => a.seq - b.seq)
				.find((item) => entry.text.startsWith(item.text) && (entry.files ?? 0) === (item.uploads?.length ?? 0));
			if (match === undefined) continue;
			used.add(match.requestId);
			// The withdraw in its turn reports it delivered
			if (match.state.type === "withdrawing") continue;
			this.#reachedModel(match, entry.id);
		}
	}

	/** The message placed as this entry, if this device sent it. */
	placedAs(conversationId: number, entryId: number): OutgoingMessage | undefined {
		return this.state.items.find(
			(item) => item.conversationId === conversationId && item.state.type === "placed" && item.state.entryId === entryId,
		);
	}

	/** A placed message's entry is a row of the transcript now: the outbox is done with it. */
	settle(requestId: string): void {
		const index = this.state.items.findIndex((item) => item.requestId === requestId);
		if (index >= 0 && this.state.items[index]!.state.type === "placed") this.#remove(index);
	}

	// MARK: Sending

	/** Starts the next operation of every conversation with none in flight, and the next create. */
	pump(): void {
		const conversations = new Set<number>();
		for (const item of this.state.items) if (item.conversationId !== undefined) conversations.add(item.conversationId);
		for (const transient of this.#transients) if (transient.conversationId !== undefined) conversations.add(transient.conversationId);
		for (const conversationId of conversations) this.#pumpConversation(conversationId);
		this.#pumpCreates();
	}

	#nextOperation(conversationId: number): Operation | undefined {
		let best: { seq: number; operation: Operation } | undefined;
		for (const item of this.state.items) {
			if (item.conversationId !== conversationId) continue;
			let operation: Operation | undefined;
			if (item.state.type === "pending" || (item.state.type === "queued" && item.needsRefresh)) {
				operation = { type: "submit", requestId: item.requestId };
			} else if (item.state.type === "withdrawing") {
				operation = { type: "withdraw", requestId: item.requestId };
			}
			if (operation !== undefined && (best === undefined || item.seq < best.seq)) best = { seq: item.seq, operation };
		}
		for (const transient of this.#transients) {
			if (transient.conversationId !== conversationId) continue;
			if (best === undefined || transient.seq < best.seq) best = { seq: transient.seq, operation: { type: "transient", seq: transient.seq } };
		}
		return best?.operation;
	}

	#pumpConversation(conversationId: number): void {
		const key = `c${conversationId}`;
		if (this.#inFlight.has(key) || this.#backoff.has(key)) return;
		const operation = this.#nextOperation(conversationId);
		if (operation === undefined) return;
		const again = () => this.#pumpConversation(conversationId);
		if (operation.type === "withdraw") {
			const item = this.item(operation.requestId)!;
			// Never written to a socket: nothing to ask the server
			if (!item.wasSent) {
				this.#finishWithdraw(item, false, undefined);
				return again();
			}
			this.#send(key, "submission.withdraw", { conversationId, requestId: item.requestId }, (result) =>
				this.#handleWithdraw(item.requestId, conversationId, result),
			);
			return;
		}
		if (operation.type === "submit") {
			const item = this.item(operation.requestId)!;
			// The second half of a move waits on the first
			if (item.replaces !== undefined) {
				const delivered = this.state.withdrawOutcomes[item.replaces];
				if (delivered === true || (delivered === undefined && this.item(item.replaces) === undefined)) {
					// Got through first, or nobody knows: a duplicate is worse than not moving it
					this.#remove(this.state.items.indexOf(item));
					if (delivered) this.#events.notice?.(conversationId, "The message reached the agent before it could move");
					return again();
				}
				if (delivered === undefined) return;
			}
			if (this.#client === undefined) return;
			const pending = item.uploads?.findIndex((upload) => upload.serverId === undefined) ?? -1;
			if (pending >= 0) return this.#uploadNext(item, pending, conversationId, key);
			if (!item.wasSent) {
				// Persisted before it is on the wire: from now on a cancel must ask the server
				item.wasSent = true;
				this.#save();
			}
			this.#send(
				key,
				"conversation.submit",
				{
					conversationId,
					requestId: item.requestId,
					content: item.text,
					whenBusy: item.mode,
					...(item.uploads && {
						attachments: item.uploads.map((upload) => ({ id: upload.serverId, as: upload.kind === "photo" ? "image" : "file" })),
					}),
				},
				(result) => this.#handleSubmit(item.requestId, conversationId, result),
			);
			return;
		}
		const transient = this.#transients.find((each) => each.seq === operation.seq)!;
		if (transient.deadline !== undefined && this.#now() > transient.deadline) {
			this.#transients.splice(this.#transients.indexOf(transient), 1);
			transient.reject(new RequestError("timeout", "Not sent in time"));
			return again();
		}
		this.#send(key, transient.method, transient.params, (result) => {
			if ("error" in result && isConnectionError(result.error) && transient.repeatable) return;
			this.#transients.splice(this.#transients.indexOf(transient), 1);
			if ("error" in result) transient.reject(result.error);
			else transient.resolve(result.value);
		});
	}

	/** One request on the current connection, once what led to it is persisted; then the conversation's next. */
	#send(key: string, method: string, params: Record<string, unknown>, handle: (result: { value: any } | { error: Error }) => void): void {
		const client = this.#client;
		if (client === undefined) return;
		this.#inFlight.add(key);
		void this.#saved
			.then(() => (this.#client === client ? client.request(method, params) : Promise.reject(new Error("disconnected"))))
			.then(
				(value) => ({ value }),
				(error: Error) => ({ error }),
			)
			.then((result) => {
				this.#inFlight.delete(key);
				handle(result);
				this.pump();
			});
	}

	/**
	 * Uploads one of a message's files, then goes on with the message: the next upload, or its submit. A file the server
	 * refuses fails the message; a network failure is tried again, as a submit is.
	 */
	#uploadNext(item: OutgoingMessage, index: number, conversationId: number, key: string): void {
		const upload = item.uploads![index]!;
		if (this.#upload === undefined) return;
		this.#inFlight.add(key);
		void this.#upload(upload).then(
			(serverId) => {
				this.#inFlight.delete(key);
				upload.serverId = serverId;
				item.attempts = 0;
				this.#save();
				this.pump();
			},
			(error: Error) => {
				this.#inFlight.delete(key);
				if (!this.state.items.includes(item)) return this.pump();
				const status = error instanceof UploadError ? error.status : 0;
				if (status === 0 || status === 401 || (status >= 500 && item.attempts + 1 < MAX_ATTEMPTS)) {
					// The network, a token the socket is refused for too, or the server failing: later
					item.attempts = status === 0 ? Math.min(item.attempts + 1, 4) : item.attempts + 1;
					this.#save();
					this.#wait(key, status === 401 ? 4 : item.attempts);
					return;
				}
				this.#update(item, (each) => {
					each.state = { type: "failed", code: status === 413 ? "too_large" : "bad_request", message: error.message };
					each.showsInQueue = false;
				});
				this.pump();
			},
		);
	}

	#handleSubmit(requestId: string, conversationId: number, result: { value: any } | { error: Error }): void {
		const item = this.item(requestId);
		if (item === undefined) return;
		if ("value" in result) {
			item.attempts = 0;
			const record = result.value?.submission as JsonObject | undefined;
			if (record === undefined) return;
			// Cancelled while the submit was out: the withdraw in its turn settles it
			if (item.state.type === "withdrawing") {
				item.submissionId = record.id as number;
				this.#save();
				return;
			}
			item.needsRefresh = false;
			this.apply(record);
			this.#save();
			return;
		}
		const { error } = result;
		// Sent again, with the same request ID, once connected; or refused or withdrawn either way
		if (isConnectionError(error) || item.state.type === "withdrawing") return;
		const code = (error as RequestError).code;
		if (code === "withdrawn") {
			this.#remove(this.state.items.indexOf(item));
		} else if (code === "file_missing" && item.uploads !== undefined && item.attempts + 1 < MAX_ATTEMPTS) {
			// Not used for a day, the server swept them: upload them again
			item.attempts += 1;
			for (const upload of item.uploads) delete upload.serverId;
			this.#save();
		} else if (code === "internal" && item.attempts + 1 < MAX_ATTEMPTS) {
			item.attempts += 1;
			this.#save();
			this.#wait(`c${conversationId}`, item.attempts);
		} else {
			const message =
				code === "not_found"
					? "This chat no longer exists"
					: code === "file_missing"
						? "A file of this message is no longer on the server"
						: error.message;
			this.#update(item, (each) => {
				each.state = { type: "failed", code, message };
				each.showsInQueue = false;
				each.needsRefresh = false;
			});
		}
	}

	#handleWithdraw(requestId: string, conversationId: number, result: { value: any } | { error: Error }): void {
		const item = this.item(requestId);
		if (item === undefined) return;
		if ("value" in result) {
			const entry = (result.value?.submission as JsonObject | undefined)?.entry as number | undefined;
			switch (result.value?.result) {
				case "withdrawn":
				case "aborted":
					return this.#finishWithdraw(item, false, undefined);
				case "already_placed":
					return this.#finishWithdraw(item, true, entry);
				default:
					// Settled before: in the transcript if it has an entry
					return this.#finishWithdraw(item, entry !== undefined, entry);
			}
		}
		if (isConnectionError(result.error)) return;
		if ((result.error as RequestError).code === "not_found") return this.#finishWithdraw(item, false, undefined);
		// A withdraw is never given up: the message must not stay half cancelled
		item.attempts += 1;
		this.#save();
		this.#wait(`c${conversationId}`, item.attempts);
	}

	#finishWithdraw(item: OutgoingMessage, delivered: boolean, entryId: number | undefined): void {
		if (this.state.items.some((each) => each.replaces === item.requestId)) this.state.withdrawOutcomes[item.requestId] = delivered;
		if (delivered) {
			if (entryId !== undefined) {
				this.#reachedModel(item, entryId);
			} else {
				this.#update(item, (each) => {
					each.state = { type: "pending" };
					each.restoresOnWithdraw = false;
				});
			}
			if (item.conversationId !== undefined) this.#events.notice?.(item.conversationId, "Already delivered");
			return;
		}
		this.#remove(this.state.items.indexOf(item));
		if (item.restoresOnWithdraw && item.conversationId !== undefined && item.text !== "") {
			this.#events.restored?.(item.conversationId, item.text);
		}
	}

	#pumpCreates(): void {
		const key = "create";
		if (this.#inFlight.has(key) || this.#backoff.has(key) || this.#client === undefined) return;
		const create = this.state.creates[0];
		if (create === undefined) return;
		this.#sendingCreate = create.requestId;
		const params: Record<string, unknown> =
			create.forkOf !== undefined
				? { conversationId: create.forkOf, at: create.forkAt, requestId: create.requestId }
				: { requestId: create.requestId, autoTitle: create.autoTitle ?? true };
		if (create.title !== undefined) params.title = create.title;
		if (create.agent !== undefined && Object.keys(create.agent).length > 0) params.agent = create.agent;
		this.#send(key, create.forkOf !== undefined ? "conversation.fork" : "conversation.create", params, (result) => {
			this.#sendingCreate = undefined;
			this.#handleCreate(create.requestId, result);
		});
	}

	#handleCreate(requestId: string, result: { value: any } | { error: Error }): void {
		const index = this.state.creates.findIndex((create) => create.requestId === requestId);
		if (index < 0) return;
		const create = this.state.creates[index]!;
		if ("value" in result) {
			const dialog = result.value?.dialog as JsonObject | undefined;
			const conversationId = (dialog?.conversation as JsonObject | undefined)?.id as number | undefined;
			if (dialog === undefined || conversationId === undefined) return;
			this.state.creates.splice(index, 1);
			this.state.created[requestId] = conversationId;
			for (const item of this.itemsOfCreate(requestId)) item.conversationId = conversationId;
			for (const transient of this.#transients) {
				if (transient.createRequestId !== requestId || transient.conversationId !== undefined) continue;
				transient.conversationId = conversationId;
				transient.params = { ...transient.params, conversationId };
			}
			this.#save();
			this.#events.created?.(create, conversationId, dialog);
			this.#events.changed?.(undefined);
			this.#events.changed?.(conversationId);
			return;
		}
		const { error } = result;
		if (isConnectionError(error)) return;
		const code = (error as RequestError).code;
		if (code === "internal" && create.attempts + 1 < MAX_ATTEMPTS) {
			create.attempts += 1;
			this.#save();
			this.#wait("create", create.attempts);
			return;
		}
		// The conversation cannot be made: its messages fail with the reason
		this.state.creates.splice(index, 1);
		for (const item of this.itemsOfCreate(requestId)) item.state = { type: "failed", code, message: error.message };
		const waiting = this.#transients.filter((each) => each.createRequestId === requestId && each.conversationId === undefined);
		this.#transients = this.#transients.filter((each) => !waiting.includes(each));
		for (const transient of waiting) transient.reject(error);
		this.#save();
		this.#events.changed?.(undefined);
	}

	// MARK: Bookkeeping

	#markWithdrawing(requestId: string, restore: boolean): boolean {
		const item = this.item(requestId);
		if (item === undefined) return false;
		switch (item.state.type) {
			case "placed":
			case "failed":
				return false;
			case "withdrawing":
				item.restoresOnWithdraw ||= restore;
				this.#save();
				return true;
		}
		item.state = { type: "withdrawing" };
		item.restoresOnWithdraw = restore;
		item.needsRefresh = false;
		// After everything already asked of this conversation
		item.seq = this.#takeSeq();
		this.#save();
		this.#events.changed?.(item.conversationId);
		return true;
	}

	#appendReplacement(item: OutgoingMessage, conversationId: number, mode: SendMode, showsInQueue: boolean): void {
		const replacement: OutgoingMessage = {
			requestId: this.#newId(),
			conversationId,
			text: item.text,
			// Uploaded ones go again by their IDs, the others from the same bytes
			...(item.uploads && { uploads: item.uploads.map((upload) => ({ ...upload })) }),
			mode,
			date: this.#now(),
			state: { type: "pending" },
			wasSent: false,
			attempts: 0,
			showsInQueue,
			seq: this.#takeSeq(),
			replaces: item.requestId,
		};
		this.state.items.push(replacement);
		this.#events.changed?.(conversationId);
	}

	#reachedModel(item: OutgoingMessage, entryId: number): void {
		this.#update(item, (each) => {
			each.state = { type: "placed", entryId };
			each.needsRefresh = false;
		});
		this.#events.placed?.(item, entryId);
	}

	#remove(index: number): void {
		if (index < 0) return;
		const [item] = this.state.items.splice(index, 1);
		if (!this.state.items.some((each) => each.replaces === item!.requestId)) delete this.state.withdrawOutcomes[item!.requestId];
		if (item!.replaces !== undefined) delete this.state.withdrawOutcomes[item!.replaces];
		this.#save();
		const used = new Set(this.state.items.flatMap((each) => each.uploads?.map((upload) => upload.key) ?? []));
		this.#events.removed?.(item!, item!.uploads?.map((upload) => upload.key).filter((key) => !used.has(key)) ?? []);
		this.#events.changed?.(item!.conversationId);
	}

	#update(item: OutgoingMessage, change: (item: OutgoingMessage) => void): void {
		change(item);
		this.#save();
		this.#events.changed?.(item.conversationId);
	}

	#changedAll(): void {
		this.#events.changed?.(undefined);
		for (const id of new Set(this.state.items.map((item) => item.conversationId))) if (id !== undefined) this.#events.changed?.(id);
	}

	#takeSeq(): number {
		return this.state.nextSeq++;
	}

	/** Backoff for one key: 1, 2, 4, 8 s. */
	#wait(key: string, attempt: number): void {
		this.#backoff.add(key);
		this.#delay(1000 * 2 ** Math.max(0, attempt - 1), () => {
			this.#backoff.delete(key);
			this.pump();
		});
	}

	/** Writes a copy, in order after every earlier write: a request goes out once what led to it is written. */
	#save(): void {
		const snapshot = structuredClone(this.state);
		this.#saved = this.#saved.then(() => this.#persist(snapshot)).catch(() => undefined);
	}
}
