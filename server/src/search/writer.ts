// Where the search index's writes go. In the server's thread, at once; during a backfill into a file, to a worker
// thread with its own connection to it (./backfill-worker.ts; a release's bundle has it as backfill-worker.js beside it), so the minutes a large database takes to index the first
// time (full-text inserts, all synchronous SQLite work) leave the server's thread free to answer.
import { Worker } from "node:worker_threads";
import type { ConversationInfo, IndexEntry, SearchIndex } from "./index.ts";
import type { UsageLedger, UsageRow, WarmRow } from "./usage.ts";

export type IndexWriter = {
	add(entries: IndexEntry[], usage: UsageRow[]): void;
	addTools(conversationId: number, entries: IndexEntry[], upTo: number): void;
	setTitle(conversationId: number, title: string): void;
	setArchived(conversationId: number, archived: boolean): void;
	setConversation(conversationId: number, info: ConversationInfo): void;
	addWarm(row: WarmRow): void;
	addCompaction(row: WarmRow): void;
};

/** A write, as the worker takes it. */
export type WriteMessage =
	| { type: "add"; entries: IndexEntry[]; usage: UsageRow[] }
	| { type: "tools"; conversationId: number; entries: IndexEntry[]; upTo: number }
	| { type: "title"; conversationId: number; title: string }
	| { type: "archived"; conversationId: number; archived: boolean }
	| { type: "conversation"; conversationId: number; info: ConversationInfo }
	| { type: "warm"; row: WarmRow }
	| { type: "compaction"; row: WarmRow };

/** Writes in this thread. */
export function localWriter(index: SearchIndex, usage: UsageLedger): IndexWriter {
	return {
		add(entries, rows) {
			index.add(entries);
			usage.add(rows);
		},
		addTools: (conversationId, entries, upTo) => index.addTools(conversationId, entries, upTo),
		setTitle: (conversationId, title) => index.setTitle(conversationId, title),
		setArchived: (conversationId, archived) => index.setArchived(conversationId, archived),
		setConversation: (conversationId, info) => index.setConversation(conversationId, info),
		addWarm: (row) => usage.addWarm(row),
		addCompaction: (row) => usage.addCompaction(row),
	};
}

/** Batches of entries the worker may have unwritten before `room()` waits. */
const IN_FLIGHT = 4;

/** Writes in a worker thread, in the order given; `finish()` once every one is written. */
export class WorkerWriter implements IndexWriter {
	readonly #worker: Worker;
	#inFlight = 0;
	#waiting: (() => void)[] = [];
	#failure: Error | undefined;
	#closing = false;
	readonly #exited: Promise<void>;

	constructor(path: string) {
		this.#worker = new Worker(new URL(import.meta.url.endsWith(".ts") ? "./backfill-worker.ts" : "./backfill-worker.js", import.meta.url), { workerData: { path } });
		this.#worker.on("message", () => {
			this.#inFlight -= 1;
			this.#wake();
		});
		this.#exited = new Promise((resolve) =>
			this.#worker.once("exit", (code) => {
				if (!this.#closing) this.#failure ??= new Error(`The search index worker exited (${code})`);
				resolve();
				this.#wake();
			}),
		);
		this.#worker.on("error", (error) => {
			this.#failure = error;
		});
	}

	add(entries: IndexEntry[], usage: UsageRow[]): void {
		if (entries.length === 0 && usage.length === 0) return;
		this.#post({ type: "add", entries, usage });
	}

	addTools(conversationId: number, entries: IndexEntry[], upTo: number): void {
		this.#post({ type: "tools", conversationId, entries, upTo });
	}

	setTitle(conversationId: number, title: string): void {
		this.#post({ type: "title", conversationId, title });
	}

	setArchived(conversationId: number, archived: boolean): void {
		this.#post({ type: "archived", conversationId, archived });
	}

	setConversation(conversationId: number, info: ConversationInfo): void {
		this.#post({ type: "conversation", conversationId, info });
	}

	addWarm(row: WarmRow): void {
		this.#post({ type: "warm", row });
	}

	addCompaction(row: WarmRow): void {
		this.#post({ type: "compaction", row });
	}

	/** Resolves once the worker is at most a few batches behind; rejects if it failed. */
	async room(): Promise<void> {
		while (this.#inFlight > IN_FLIGHT && this.#failure === undefined) await new Promise<void>((resolve) => this.#waiting.push(resolve));
		if (this.#failure !== undefined) throw this.#failure;
	}

	/** Every write written and the worker's connection closed. */
	async finish(): Promise<void> {
		while (this.#inFlight > 0 && this.#failure === undefined) await new Promise<void>((resolve) => this.#waiting.push(resolve));
		if (this.#failure !== undefined) throw this.#failure;
		this.#closing = true;
		this.#worker.postMessage({ type: "close" });
		await this.#exited;
	}

	/** Stops the worker, written or not. */
	async terminate(): Promise<void> {
		this.#closing = true;
		await this.#worker.terminate();
	}

	#post(message: WriteMessage): void {
		if (this.#failure !== undefined) return;
		this.#inFlight += 1;
		this.#worker.postMessage(message);
	}

	#wake(): void {
		for (const resolve of this.#waiting.splice(0)) resolve();
	}
}
