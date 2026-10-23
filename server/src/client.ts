// Reference client: what the iOS app does, in TypeScript. Used by the tests and the CLI.
// Ops are applied by a standalone implementation of docs/protocol.md, not Chord's, to keep the spec honest.
import WebSocket from "ws";

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };
export type Entry = { id: number; kind: string; conversationId: number; head?: number; [key: string]: unknown };
export type Op =
	| ["r", Json]
	| ["s", (string | number)[], Json]
	| ["d", (string | number)[]]
	| ["a", (string | number)[], string]
	| ["t", (string | number)[], number]
	| ["p", (string | number)[], number, number, Json[]]
	| ["m", (string | number)[], number[]];

export type Push = { event: string; [key: string]: unknown };

export class RequestError extends Error {
	readonly code: string;
	constructor(code: string, message: string) {
		super(message);
		this.name = "RequestError";
		this.code = code;
	}
}

export class TauClient {
	readonly #socket: WebSocket;
	readonly #pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
	readonly #listeners = new Set<(push: Push) => void>();
	#nextId = 1;
	readonly closed: Promise<void>;

	private constructor(socket: WebSocket) {
		this.#socket = socket;
		socket.on("message", (data) => {
			const message = JSON.parse(data.toString()) as { id?: number; result?: unknown; error?: { code: string; message: string }; event?: string };
			if (message.event !== undefined) {
				for (const listener of this.#listeners) listener(message as Push);
				return;
			}
			const pending = this.#pending.get(message.id!);
			if (pending === undefined) return;
			this.#pending.delete(message.id!);
			if (message.error !== undefined) pending.reject(new RequestError(message.error.code, message.error.message));
			else pending.resolve(message.result);
		});
		this.closed = new Promise((resolve) =>
			socket.once("close", () => {
				for (const pending of this.#pending.values()) pending.reject(new Error("connection closed"));
				this.#pending.clear();
				resolve();
			}),
		);
	}

	/** `media`: entries come with image references, fetched with `media.get` (src/media.ts). */
	static async connect(url: string, token?: string): Promise<TauClient> {
		const socket = new WebSocket(url, token === undefined ? {} : { headers: { authorization: `Bearer ${token}` } });
		await new Promise<void>((resolve, reject) => {
			socket.once("open", resolve);
			socket.once("error", reject);
		});
		const client = new TauClient(socket);
		await client.request("hello", { protocol: 1 });
		return client;
	}

	request<T = any>(method: string, params: Record<string, unknown> = {}): Promise<T> {
		const id = this.#nextId++;
		return new Promise<T>((resolve, reject) => {
			this.#pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
			this.#socket.send(JSON.stringify({ id, method, params }));
		});
	}

	on(listener: (push: Push) => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	close(): Promise<void> {
		this.#socket.close();
		return this.closed;
	}
}

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
		const result = await client.request("conversation.subscribe", {
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
		const result = await client.request("conversation.history", { conversationId: this.id, before: oldest, limit });
		this.#upsert(result.entries);
		this.hasOlder = result.hasOlder;
		this.#emit();
	}

	/** Fill the newest hole, one page at a time. */
	async fillHole(client: TauClient, limit = 50): Promise<void> {
		const hole = this.holes.at(-1);
		if (hole === undefined) return;
		const result = await client.request("conversation.history", {
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

/** Apply protocol ops to a JSON value immutably. */
export function applyOps(value: Json, ops: readonly Op[]): Json {
	let root = structuredClone(value);
	for (const op of ops) {
		if (op[0] === "r") {
			root = structuredClone(op[1]);
			continue;
		}
		const path = op[1];
		if (op[0] === "p" || op[0] === "m") {
			const array = resolve(root, path) as Json[];
			if (op[0] === "p") array.splice(op[2], op[3], ...structuredClone(op[4]));
			else {
				const old = [...array];
				op[2].forEach((from, to) => {
					array[to] = old[from]!;
				});
			}
			continue;
		}
		const parent = resolve(root, path.slice(0, -1)) as Record<string | number, Json>;
		const key = path.at(-1)!;
		switch (op[0]) {
			case "s":
				parent[key] = structuredClone(op[2]);
				break;
			case "d":
				if (Array.isArray(parent)) parent.splice(key as number, 1);
				else delete parent[key];
				break;
			case "a":
				parent[key] = (parent[key] as string) + op[2];
				break;
			case "t":
				parent[key] = (parent[key] as string).slice(op[2]);
				break;
		}
	}
	return root;
}

function resolve(root: Json, path: readonly (string | number)[]): Json {
	let node = root;
	for (const key of path) node = (node as Record<string | number, Json>)[key]!;
	return node;
}
