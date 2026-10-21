// Push notifications: when a conversation's run ends with an answer, and no client is in the foreground to show its own
// banner, the server tells the user's phone. Today through ntfy (ntfy.sh or a self-hosted one): the phone's ntfy app
// gets the push and its tap opens tau at the chat. Apple's push would be a second transport here: the decision of what
// to send and when stays the same, only the delivery differs.
import type { AssistantMessage } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ConversationId, EntryRecord } from "@earendil-works/pi-durable";
import { type Host, MetaDoc, SettingsDoc } from "./host.ts";

/** Where pushes go: an ntfy server and a topic only the user's phone subscribes to. */
export type NtfyTarget = { server: string; topic: string };

function textOf(message: AssistantMessage | undefined): string {
	return (message?.content ?? []).flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

export class Notifier {
	readonly #host: Host;
	readonly #unsubscribe: () => void;
	/** Connections whose app is in the foreground: they show banners, so nothing is pushed. */
	#activeClients = 0;
	#closed = false;
	/** For tests: the pushes sent. */
	readonly sent: { conversationId: ConversationId; title: string; message: string }[] = [];
	/** Replaces fetch in tests. */
	post: (url: string, body: unknown) => Promise<void> = async (url, body) => {
		await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
	};

	constructor(host: Host) {
		this.#host = host;
		this.#unsubscribe = host.harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type !== "entry" || change.value.kind !== "pi.assistant") continue;
				const message = change.value.model?.[0] as AssistantMessage | undefined;
				// The end of a run: a final answer, or one that failed. A tool round goes on.
				if (message === undefined || message.stopReason === "toolUse") continue;
				const entry = change.value;
				// Commit listeners must not call Session APIs.
				setTimeout(() => {
					if (this.#closed) return;
					this.#notify(entry, message).catch((error) => console.error("[tau] push failed:", error));
				}, 0);
			}
		});
	}

	/** A connection's app came to the foreground (+1) or left it (-1). */
	presence(delta: number): void {
		this.#activeClients = Math.max(0, this.#activeClients + delta);
	}

	get activeClients(): number {
		return this.#activeClients;
	}

	close(): void {
		this.#closed = true;
		this.#unsubscribe();
	}

	async #notify(entry: EntryRecord, message: AssistantMessage): Promise<void> {
		const context = BACKGROUND_CONTEXT;
		const { harness, storage } = this.#host;
		const target = (await harness.snapshot(SettingsDoc, context))?.ntfy;
		if (target === undefined || this.#activeClients > 0) return;
		const id = entry.conversationId;
		// A subagent's answer goes to the conversation that started it, which reports it in its own answer.
		const record = await storage.conversation(id, context);
		if (record === undefined || record.owner !== undefined) return;
		const meta = await harness.snapshot(MetaDoc, id, context);
		const title = meta?.title ?? "tau";
		const failed = message.stopReason === "error" || message.stopReason === "aborted";
		const text = failed ? `Failed: ${message.errorMessage ?? "the model stopped"}` : textOf(message);
		const body = text.replace(/\s+/g, " ").trim().slice(0, 400) || "Answered.";
		this.sent.push({ conversationId: id, title, message: body });
		await this.post(target.server.replace(/\/+$/, ""), {
			topic: target.topic,
			title,
			message: body,
			// The ntfy app opens this on a tap: tau's URL for the chat (ios/Tau/App/AppDelegate.swift).
			click: `tau://chat?server=${this.#host.serverId}&id=${id}`,
			tags: failed ? ["warning"] : ["robot"],
		});
	}
}
