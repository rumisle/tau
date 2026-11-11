// One connection to a tau server (docs/protocol.md "Frames"): requests by ID, pushes to listeners, `hello` first. The
// socket is given, so the same client runs on a browser's WebSocket and on Node's `ws`.
import type { Push } from "./protocol.ts";

/** What the client needs of a socket: the WHATWG WebSocket's interface, which `ws` implements too. */
export interface SocketLike {
	send(data: string): void;
	close(): void;
	addEventListener(type: "open" | "message" | "close" | "error", listener: (event: any) => void): void;
}

export class RequestError extends Error {
	readonly code: string;
	constructor(code: string, message: string) {
		super(message);
		this.name = "RequestError";
		this.code = code;
	}
}

export type Hello = { protocol: number; serverId: string; [key: string]: unknown };

export class TauClient {
	readonly #socket: SocketLike;
	readonly #pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();
	readonly #listeners = new Set<(push: Push) => void>();
	#nextId = 1;
	/** Resolves when the socket closes; every request still waiting is rejected then. */
	readonly closed: Promise<void>;
	hello: Hello | undefined;

	private constructor(socket: SocketLike) {
		this.#socket = socket;
		socket.addEventListener("message", (event: { data: unknown }) => {
			const message = JSON.parse(String(event.data)) as { id?: number; result?: unknown; error?: { code: string; message: string }; event?: string };
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
			socket.addEventListener("close", () => {
				for (const pending of this.#pending.values()) pending.reject(new Error("connection closed"));
				this.#pending.clear();
				resolve();
			}),
		);
	}

	/** Waits for `socket` to open, then greets the server. Rejects when the socket fails first (a refused token: 401). */
	static async open(socket: SocketLike): Promise<TauClient> {
		await new Promise<void>((resolve, reject) => {
			socket.addEventListener("open", () => resolve());
			socket.addEventListener("error", (event: { message?: string; error?: Error }) =>
				reject(event.error ?? new Error(event.message ?? "the connection failed")),
			);
			socket.addEventListener("close", () => reject(new Error("the connection closed before it opened")));
		});
		const client = new TauClient(socket);
		client.hello = await client.request<Hello>("hello", { protocol: 1 });
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
