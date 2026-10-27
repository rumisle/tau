// One client connection: request dispatch, conversation subscriptions, and pushes. See docs/protocol.md.
import type { Context, JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT, withCancel } from "@earendil-works/chord/context";
import type { Op } from "@earendil-works/chord/delta";
import { clampThinkingLevel, getSupportedThinkingLevels, type ImageContent, type ModelThinkingLevel, type TextContent } from "@earendil-works/pi-ai";
import {
	type AgentChange,
	AgentDoc,
	type Conversation,
	ConversationBusy,
	type ConversationId,
	type ConversationWatch,
	type Cursor,
	type EntryId,
	type EntryRecord,
	type ModelRef,
	type SubmissionId,
} from "@earendil-works/pi-durable";
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { attachmentsText, ownText } from "./attachments.ts";
import type { StoredFile } from "./files.ts";
import { DEFAULT_IMAGE_LIMITS } from "@earendil-works/pi-durable/tools";
import { homedir, hostname } from "node:os";
import { CACHE_WARMING_MODES, type CacheWarmingMode } from "./cache.ts";
import { type CompactionThreshold, MAX_COMPACTION_RATIO, MIN_COMPACTION_RATIO, MIN_COMPACTION_TOKENS } from "./compaction.ts";
import type { Dialogs } from "./dialogs.ts";
import { entryImages } from "./media.ts";
import { clientDocs, clientEntry, clientOp } from "./outgoing.ts";
import type { KindName } from "./search/index.ts";
import type { Search } from "./search/service.ts";
import { CreatesDoc, type Host, MetaDoc } from "./host.ts";
import type { ActivityRow } from "./devices.ts";
import type { Notifier } from "./notifier.ts";
import { isPushKey } from "./seal.ts";
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
/** Files one message may carry (docs/files.md), each up to the server's file limit. */
const MAX_ATTACHMENTS = 20;
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
	"conversation.rename",
]);

const THINKING_LEVELS: readonly ModelThinkingLevel[] = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/** Longest conversation title a rename takes. */
const MAX_TITLE_CHARS = 64;

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


/** The pi commit the server links (PI_REVISION at the repository root), reported in `hello`; a release has it built in. */
const PI_REVISION = (() => {
	if (typeof TAU_PI_REVISION === "string") return TAU_PI_REVISION;
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
	readonly #notifier: Notifier | undefined;
	readonly #search: Search | undefined;
	/** This client's app is in the foreground (client.presence). */
	#active = false;

	constructor(host: Host, dialogs: Dialogs, socket: Socket, notifier?: Notifier, search?: Search) {
		this.#host = host;
		this.#notifier = notifier;
		this.#search = search;
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
			if (request.method === "hello") {
				// Answered before the next frame is read, so its answer comes before any other: a client may send its
				// subscriptions right behind it, for the database it expects, and check the hello's serverId first.
				this.#push({ id: request.id, result: this.#helloRequest(params) });
				return;
			}
			if (request.method === "dialogs.subscribe") {
				if (!this.#hello) throw new ProtocolError("bad_request", "Send hello first");
				const since = str(params, "since", true);
				await this.#dialogs.ready();
				await this.#dialogs.settled();
				// The listener and the list in one step: every later change comes as an event after the response.
				this.#stopDialogs ??= this.#dialogs.onDialog((dialog, version) => this.#push({ event: "dialog", dialog, version }));
				// The list as the Dialogs keep it serialized: the same frame as `#push({ id, result: list(since) })`.
				this.#send(`{${request.id === undefined ? "" : `"id":${JSON.stringify(request.id)},`}"result":${this.#dialogs.serializedList(since)}}`);
				return;
			}
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
		if (this.#active) this.#notifier?.presence(-1);
		this.#cancel();
		for (const cleanup of this.#cleanups) cleanup();
		this.#stopDialogs?.();
		const watches = [...this.#subscriptions.values()].map((subscription) => subscription.watch.stop());
		this.#subscriptions.clear();
		await Promise.allSettled(watches);
	}

	async #dispatch(method: string, params: Record<string, unknown>): Promise<unknown> {
		if (!this.#hello) throw new ProtocolError("bad_request", "Send hello first");
		const context = this.#context;
		const { harness } = this.#host;
		switch (method) {
			case "models.list":
				return this.#models();
			case "devices.register": {
				// A phone's APNs registration (src/notifier.ts): its device token once the user allows notifications,
				// whether it wants answers, and the token that starts a Live Activity.
				const environment = str(params, "environment");
				if (environment !== "development" && environment !== "production") throw new ProtocolError("bad_request", "environment must be development or production");
				const nullable = (key: string): string | null | undefined => (params[key] === null ? null : str(params, key, true));
				const pushKey = (key: string | null | undefined) => {
					if (typeof key === "string" && key !== "" && !isPushKey(key)) throw new ProtocolError("bad_request", "pushKey must be 32 bytes, base64");
					return key;
				};
				const alerts = params.alerts;
				if (alerts !== undefined && typeof alerts !== "boolean") throw new ProtocolError("bad_request", "alerts must be a boolean");
				await this.#requireNotifier().register(str(params, "deviceId"), {
					environment,
					topic: str(params, "topic"),
					...(alerts === undefined ? {} : { alerts }),
					...(params.token === undefined ? {} : { token: nullable("token") }),
					...(params.pushToStart === undefined ? {} : { pushToStart: nullable("pushToStart") }),
					...(params.pushKey === undefined ? {} : { pushKey: pushKey(nullable("pushKey")) }),
				});
				return {};
			}
			case "devices.unregister": {
				await this.#requireNotifier().unregister(str(params, "deviceId"));
				return {};
			}
			case "liveActivity.update": {
				const activity = params.activity === null ? null : obj(params, "activity");
				if (activity === undefined) throw new ProtocolError("bad_request", "activity must be an object or null");
				await this.#requireNotifier().updateActivity(
					str(params, "deviceId"),
					activity === null
						? null
						: {
								...(str(activity, "id", true) === undefined ? {} : { id: str(activity, "id") }),
								...(str(activity, "token", true) === undefined ? {} : { token: str(activity, "token") }),
								rows: activityRows(activity.rows),
								...(activity.accent === undefined ? {} : { accent: int(activity, "accent") }),
							},
				);
				return {};
			}
			case "liveActivity.start": {
				const result = await this.#requireNotifier().startActivity(str(params, "deviceId"), activityRows(params.rows), params.accent === undefined ? undefined : int(params, "accent"));
				return { result };
			}
			case "client.presence": {
				// The app in the foreground shows its own banners; while one is, nothing is pushed.
				const active = params.active === true;
				if (active !== this.#active) {
					this.#active = active;
					this.#notifier?.presence(active ? 1 : -1);
				}
				return {};
			}
			case "settings.configure": {
				const model = obj(params, "defaultModel");
				if (model !== undefined) {
					await this.#host.setDefaultModel({ provider: str(model, "provider"), modelId: str(model, "modelId") });
				}
				const level = str(params, "defaultThinkingLevel", true);
				if (level !== undefined) {
					if (!THINKING_LEVELS.includes(level as ModelThinkingLevel)) {
						throw new ProtocolError("bad_request", `Unknown thinking level ${level}`);
					}
					await this.#host.setDefaultThinkingLevel(level as ModelThinkingLevel);
				}
				const warming = str(params, "cacheWarming", true);
				if (warming !== undefined) {
					if (!CACHE_WARMING_MODES.includes(warming as CacheWarmingMode)) throw new ProtocolError("bad_request", `Unknown cache warming mode ${warming}`);
					await this.#host.setCacheWarming(warming as CacheWarmingMode);
				}
				const compaction = obj(params, "compaction");
				if (compaction !== undefined) await this.#host.setCompactionThreshold(compactionThreshold(compaction, this.#host.compactionThreshold));
				return { defaultModel: this.#host.defaultModel, defaultThinkingLevel: this.#host.defaultThinkingLevel, cacheWarming: this.#host.cacheWarming, compaction: this.#host.compactionThreshold };
			}
			case "search": {
				if (this.#search === undefined) throw new ProtocolError("bad_request", "Search is not available");
				const kinds = searchKinds(params.kinds);
				const conversationId = int(params, "conversationId", true);
				const query = str(params, "query");
				const typing = params.typing === true;
				if (conversationId !== undefined) return this.#search.searchConversation(conversationId, query, { kinds, typing });
				return this.#search.search(query, { limit: Math.min(int(params, "limit", true) ?? 20, 100), offset: int(params, "offset", true) ?? 0, kinds, typing }, context);
			}
			case "media.get": {
				// An image of an entry of the conversation, as the model has it.
				const conversation = await this.#conversation(params);
				const entryId = int(params, "entryId") as EntryId;
				const index = int(params, "index");
				const entry = (await conversation.entries({ minEntryId: entryId, maxEntryId: entryId }, 1, undefined, context)).items[0];
				const image = entry === undefined ? undefined : entryImages(entry)[index];
				if (image === undefined) throw new ProtocolError("not_found", `Entry ${entryId} has no image ${index}`);
				return { mimeType: image.mimeType, data: image.data };
			}
			case "usage.report": {
				if (this.#search === undefined) throw new ProtocolError("bad_request", "Usage is not available");
				return this.#search.report(Math.max(0, int(params, "days", true) ?? 30), int(params, "tzOffset", true) ?? 0);
			}
			case "conversation.create": {
				const requestId = str(params, "requestId", true);
				if (requestId !== undefined) {
					const existing = (await harness.snapshot(CreatesDoc, context))?.requests[requestId];
					if (existing !== undefined) return { dialog: await this.#dialogOf(existing as ConversationId) };
				}
				const title = str(params, "title", true);
				const autoTitle = params.autoTitle === true;
				const patch = obj(params, "agent") ?? {};
				// The defaults are fixed in the conversation now: changing them later moves no existing conversation.
				const model = (patch.model as ModelRef | undefined) ?? this.#host.defaultModel;
				const thinkingLevel = this.#fitThinking(model, (patch.thinkingLevel as ModelThinkingLevel | undefined) ?? this.#host.defaultThinkingLevel);
				const conversation = await harness.createConversation(
					{
						ownership: { kind: "ownerless" },
						agent: await agentChange({ model, ...patch, thinkingLevel: thinkingLevel === "off" ? undefined : thinkingLevel }),
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
				const patch = { ...(obj(params, "agent") ?? {}) };
				// A thinking level the model has: the one asked for, or after a model change the current one, fitted as
				// pi fits it when the model changes (clampThinkingLevel).
				if (patch.model !== undefined || patch.thinkingLevel !== undefined) {
					const current = await harness.snapshot(AgentDoc, conversation.id, context);
					const model = (patch.model as ModelRef | null | undefined) ?? current?.model ?? this.#host.defaultModel;
					const asked: ModelThinkingLevel = patch.thinkingLevel === undefined ? (current?.thinkingLevel ?? "off") : ((patch.thinkingLevel as ModelThinkingLevel | null) ?? "off");
					const fitted = this.#fitThinking(model, asked);
					if (patch.thinkingLevel !== undefined || fitted !== asked) patch.thinkingLevel = fitted === "off" ? null : fitted;
				}
				await conversation.configure(await agentChange(patch), context);
				return {};
			}
			case "conversation.rename": {
				const conversation = await this.#conversation(params);
				const title = str(params, "title").replace(/\s+/g, " ").trim();
				if (title === "" || title.length > MAX_TITLE_CHARS) {
					throw new ProtocolError("bad_request", `A title is 1 to ${MAX_TITLE_CHARS} characters`);
				}
				await conversation.commit(async (tx) => {
					const meta = await tx.doc(MetaDoc, conversation.id);
					meta.title = title;
					// A name the user gave is never replaced by an automatic one, even one being written now.
					meta.autoTitle = false;
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
					if (params.hidden === true) meta.hidden = true;
					else if (params.hidden === false) delete meta.hidden;
					if (typeof params.pinned === "number" && Number.isFinite(params.pinned)) meta.pinned = params.pinned;
					else if (params.pinned === false) delete meta.pinned;
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
			defaultThinkingLevel: this.#host.defaultThinkingLevel,
			cacheWarming: this.#host.cacheWarming,
			compaction: this.#host.compactionThreshold,
			// Whether it can send Apple's pushes: it has the account's APNs key.
			apns: this.#notifier?.canPush === true,
			// The largest file it keeps (docs/files.md).
			maxFileBytes: this.#host.files.maxBytes,
			hostname: hostname(),
			piRevision: PI_REVISION,
			uptime: Math.round(process.uptime()),
		};
	}

	#requireNotifier(): Notifier {
		if (this.#notifier === undefined) throw new ProtocolError("bad_request", "This server sends no pushes");
		return this.#notifier;
	}

	async #models(): Promise<unknown> {
		const available = await this.#host.models.getAvailable();
		return {
			models: available.map((model) => ({
				provider: model.provider,
				id: model.id,
				name: model.name,
				reasoning: model.reasoning,
				thinkingLevels: getSupportedThinkingLevels(model),
				contextWindow: model.contextWindow,
				input: model.input,
			})),
		};
	}

	/** `level` if the model has it, else the nearest level it has, as pi's clampThinkingLevel picks. */
	#fitThinking(ref: ModelRef, level: ModelThinkingLevel): ModelThinkingLevel {
		const model = this.#host.models.getModel(ref.provider, ref.modelId);
		return model === undefined ? level : clampThinkingLevel(model, level);
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
				docs: clientDocs(view.docs),
				entries: this.#outgoing(entries),
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
					docs: clientDocs(value.docs),
					...(entries.length === 0 ? {} : { entries: this.#outgoing(entries) }),
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
				if (path[0] === "docs") {
					const shown = clientOp(relative(op));
					if (shown !== undefined) docOps.push(shown);
				}
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
				...(entries.length === 0 ? {} : { entries: this.#outgoing(entries) }),
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
		// Without `before`, the newest: what a client preloading a chat it has not opened asks for.
		const before = int(params, "before", true);
		const after = int(params, "after", true);
		const page = await conversation.entries(
			{
				...(before === undefined ? {} : { maxEntryId: (before - 1) as EntryId }),
				...(after === undefined ? {} : { minEntryId: (after + 1) as EntryId }),
				order: "descending",
			},
			limit(params),
			undefined,
			this.#context,
		);
		return { entries: this.#outgoing([...page.items].reverse()), hasOlder: page.next !== undefined };
	}

	/** Entries as clients take them (src/outgoing.ts): images by reference, no replay data. */
	#outgoing(entries: readonly EntryRecord[]): EntryRecord[] {
		return entries.map(clientEntry);
	}

	async #submit(params: Record<string, unknown>): Promise<unknown> {
		const conversation = await this.#conversation(params);
		const requestId = str(params, "requestId");
		if (requestId === "") throw new ProtocolError("bad_request", "requestId must not be empty");
		const attachmentIds = attachmentList(params.attachments);
		const own = attachmentIds.length > 0 && isEmptyContent(params.content) ? [] : userContent(params.content);
		const whenBusy = str(params, "whenBusy", true) ?? "followUp";
		if (whenBusy !== "steer" && whenBusy !== "followUp" && whenBusy !== "reject") {
			throw new ProtocolError("bad_request", "whenBusy must be steer, followUp, or reject");
		}
		const { harness } = this.#host;
		const meta = await harness.snapshot(MetaDoc, conversation.id, this.#context);
		if (meta?.withdrawn?.includes(requestId)) {
			throw new ProtocolError("withdrawn", `Request ${requestId} was withdrawn`);
		}
		this.#checkContent(own);
		const attached = await this.#attachments(conversation, attachmentIds);
		const content = await withAttachments(own, attached);
		if (meta?.title === undefined) {
			const title = titleFrom(own) || (attached.length === 0 ? "" : attached.every((each) => each.shown) ? (attached.length > 1 ? `${attached.length} Photos` : "Photo") : attached[0]!.file.name);
			if (title !== "") {
				await conversation.commit(async (tx) => {
					(await tx.doc(MetaDoc, conversation.id)).title ??= title;
				}, this.#context);
			}
		}
		// Before the message is in: its uploads wait for its entry a week, not a day (src/files.ts).
		await this.#host.files.submitted(attached.map((each) => each.file.id));
		const submission = await conversation.submit({ type: "input", content, whenBusy, requestId }, this.#context);
		return { submission: await submission.status(this.#context) };
	}

	/**
	 * The uploads a message names, with whether each goes to the model as an image too: one sent as a photo, of a type
	 * and size every provider takes, to a model that takes images. The rest are files, named only.
	 */
	async #attachments(conversation: Conversation, ids: readonly { id: string; as: "image" | "file" }[]): Promise<Attached[]> {
		if (ids.length === 0) return [];
		const takesImages = await this.#takesImages(conversation);
		const result: Attached[] = [];
		for (const { id, as } of ids) {
			const file = await this.#host.files.get(id);
			if (file === undefined) throw new ProtocolError("file_missing", `No file ${id}: it was never uploaded, or not used for a day`);
			let image: ImageContent | undefined;
			if (as === "image" && takesImages && IMAGE_TYPES.has(file.mimeType)) image = await this.#shownImage(file);
			result.push({ file, shown: image !== undefined, ...(image === undefined ? {} : { image }) });
		}
		if (result.filter((each) => each.shown).length > MAX_IMAGES) throw new ProtocolError("too_large", `A message can carry at most ${MAX_IMAGES} images`);
		return result;
	}

	/**
	 * A photo as the model sees it: as it is within durable's limits (2000 pixels a side, 4.5 MB of base64), else shrunk
	 * by the image processor; undefined when it cannot be, and it goes as a file.
	 */
	async #shownImage(file: StoredFile): Promise<ImageContent | undefined> {
		const bytes = await readFile(file.path);
		const limits = DEFAULT_IMAGE_LIMITS;
		const fits = file.width !== undefined && file.height !== undefined && file.width <= limits.maxWidth && file.height <= limits.maxHeight && Math.ceil(bytes.length / 3) * 4 <= limits.maxBytes;
		if (fits) return { type: "image", mimeType: file.mimeType, data: bytes.toString("base64") };
		const prepared = await this.#host.images.prepare(bytes, file.mimeType, limits).catch(() => undefined);
		return prepared === undefined ? undefined : { type: "image", mimeType: prepared.mimeType, data: prepared.data };
	}

	async #takesImages(conversation: Conversation): Promise<boolean> {
		const ref = (await conversation.agent(this.#context)).model;
		if (ref === undefined) return true;
		const model = (await this.#host.models.getAvailable()).find((candidate) => candidate.provider === ref.provider && candidate.id === ref.modelId);
		return model === undefined || model.input.includes("image");
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
	/** Refuse text too long to send, before it is admitted. Photos and files come as attachments. */
	#checkContent(content: string | TextContent[]): void {
		const text = typeof content === "string" ? content.length : content.reduce((total, part) => total + part.text.length, 0);
		if (text > MAX_TEXT_CHARS) throw new ProtocolError("too_large", "The message is longer than 1,000,000 characters");
	}

	#push(message: unknown): void {
		this.#send(JSON.stringify(message));
	}

	#send(frame: string): void {
		if (this.#closed) return;
		this.#socket.send(frame);
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

/** A client agent patch as an AgentChange. Where a conversation runs is the server's to say (docs/protocol.md). */
async function agentChange(patch: Record<string, unknown> & AgentPatch): Promise<AgentChange> {
	const change: {
		model?: AgentChange["model"];
		thinkingLevel?: AgentChange["thinkingLevel"];
		instructions?: AgentChange["instructions"];
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
	if (patch.instructions !== undefined) {
		if (patch.instructions !== null && typeof patch.instructions !== "string") {
			throw new ProtocolError("bad_request", "agent.instructions must be a string or null");
		}
		change.instructions = patch.instructions;
	}
	return change;
}

/** What the user wrote: a string, or text blocks. Photos and files are attachments (docs/files.md). */
function userContent(value: unknown): string | TextContent[] {
	if (typeof value === "string") {
		if (value.trim() === "") throw new ProtocolError("bad_request", "content must not be empty");
		return value;
	}
	if (!Array.isArray(value) || value.length === 0) {
		throw new ProtocolError("bad_request", "content must be a string or a non-empty array of content blocks");
	}
	return value.map((part: unknown) => {
		const block = part as Record<string, JsonValue>;
		if (block?.type === "text" && typeof block.text === "string") return { type: "text" as const, text: block.text };
		throw new ProtocolError("bad_request", "content blocks must be { type: text, text }; photos and files go as attachments");
	});
}

/** `attachments`: `[{ id, as?: "image" | "file" }]`, `as` "file" by default. */
function attachmentList(value: unknown): { id: string; as: "image" | "file" }[] {
	if (value === undefined) return [];
	if (!Array.isArray(value)) throw new ProtocolError("bad_request", "attachments must be an array");
	if (value.length > MAX_ATTACHMENTS) throw new ProtocolError("too_large", `A message can carry at most ${MAX_ATTACHMENTS} files`);
	return value.map((item: unknown) => {
		const attachment = item as { id?: unknown; as?: unknown } | null;
		if (typeof attachment?.id !== "string") throw new ProtocolError("bad_request", "attachments must be { id, as? }");
		if (attachment.as !== undefined && attachment.as !== "image" && attachment.as !== "file") {
			throw new ProtocolError("bad_request", "attachments' as must be image or file");
		}
		return { id: attachment.id, as: attachment.as === "image" ? "image" : "file" };
	});
}

function isEmptyContent(value: unknown): boolean {
	return value === undefined || value === null || (typeof value === "string" && value.trim() === "") || (Array.isArray(value) && value.length === 0);
}

/** The message as the model gets it: the attachments block, the images shown, then what the user wrote. */
/** A message's file, with the image the model sees of it when it does. */
type Attached = { file: StoredFile; shown: boolean; image?: ImageContent };

async function withAttachments(own: string | (TextContent | ImageContent)[], attached: readonly Attached[]): Promise<string | (TextContent | ImageContent)[]> {
	if (attached.length === 0) return own;
	const images = attached.flatMap((each) => (each.image === undefined ? [] : [each.image]));
	const rest = typeof own === "string" ? (own === "" ? [] : [{ type: "text" as const, text: own }]) : own;
	return [{ type: "text", text: attachmentsText(attached) }, ...images, ...rest];
}

function titleFrom(content: string | (TextContent | ImageContent)[]): string {
	const text = ownText(content);
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

const SEARCH_KINDS: readonly KindName[] = ["user", "assistant", "reasoning", "title"];

function searchKinds(value: unknown): KindName[] | undefined {
	if (value === undefined) return undefined;
	if (!Array.isArray(value) || value.some((kind) => !SEARCH_KINDS.includes(kind))) {
		throw new ProtocolError("bad_request", `kinds must be some of ${SEARCH_KINDS.join(", ")}`);
	}
	return value as KindName[];
}

/** A `settings.configure` compaction change over `current`: any of `enabled`, `ratio`, `maxTokens`, checked. */
function compactionThreshold(params: Record<string, unknown>, current: CompactionThreshold): CompactionThreshold {
	const next = { ...current };
	if (params.enabled !== undefined) {
		if (typeof params.enabled !== "boolean") throw new ProtocolError("bad_request", "compaction.enabled must be a boolean");
		next.enabled = params.enabled;
	}
	if (params.ratio !== undefined) {
		if (typeof params.ratio !== "number" || !(params.ratio >= MIN_COMPACTION_RATIO && params.ratio <= MAX_COMPACTION_RATIO)) {
			throw new ProtocolError("bad_request", `compaction.ratio must be between ${MIN_COMPACTION_RATIO} and ${MAX_COMPACTION_RATIO}`);
		}
		next.ratio = params.ratio;
	}
	if (params.maxTokens !== undefined) {
		if (typeof params.maxTokens !== "number" || !Number.isSafeInteger(params.maxTokens) || params.maxTokens < MIN_COMPACTION_TOKENS) {
			throw new ProtocolError("bad_request", `compaction.maxTokens must be an integer of at least ${MIN_COMPACTION_TOKENS}`);
		}
		next.maxTokens = params.maxTokens;
	}
	return next;
}

/** A Live Activity's rows as the app sends them (src/devices.ts). */
function activityRows(value: unknown): ActivityRow[] {
	if (!Array.isArray(value) || value.length > 50) throw new ProtocolError("bad_request", "rows must be an array of at most 50");
	return value.map((raw) => {
		if (typeof raw !== "object" || raw === null) throw new ProtocolError("bad_request", "a row must be an object");
		const row = raw as Record<string, unknown>;
		const state = str(row, "state");
		if (state !== "working" && state !== "done" && state !== "failed") throw new ProtocolError("bad_request", "a row's state must be working, done or failed");
		const appId = row.appId;
		if (typeof appId !== "number" || !Number.isSafeInteger(appId)) throw new ProtocolError("bad_request", "appId must be an integer");
		return {
			appId,
			conversationId: int(row, "conversationId"),
			title: str(row, "title").slice(0, 200),
			state,
			since: int(row, "since"),
			...(row.finishedAt === undefined ? {} : { finishedAt: int(row, "finishedAt") }),
			...(str(row, "detail", true) === undefined ? {} : { detail: str(row, "detail").slice(0, 200) }),
			watchedAt: int(row, "watchedAt"),
		};
	});
}
