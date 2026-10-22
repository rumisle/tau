// Automatic titles: once a conversation that asked for one has its first answer, the conversation's model names it in a
// few words, as chat apps title new chats. The title lands in tau.meta, so every client's chat list updates.
import type { AssistantMessage, Message } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { AgentDoc, type ConversationId, type EntryRecord } from "@earendil-works/pi-durable";
import { type Host, MetaDoc } from "./host.ts";

const PROMPT =
	"Write a title for this conversation: 2 to 6 words, sentence case, no quotes, no final period. Reply with the title only.";

export class Titler {
	readonly #host: Host;
	readonly #pending = new Set<ConversationId>();
	readonly #unsubscribe: () => void;
	#closed = false;

	constructor(host: Host) {
		this.#host = host;
		this.#unsubscribe = host.harness.subscribeCommits((publication) => {
			for (const change of publication.changes) {
				if (change.type !== "entry" || change.value.kind !== "pi.assistant") continue;
				const message = change.value.model?.[0] as AssistantMessage | undefined;
				if (message?.stopReason !== "stop") continue;
				const id = change.value.conversationId;
				if (this.#pending.has(id)) continue;
				this.#pending.add(id);
				// Commit listeners must not call Session APIs.
				const entry = change.value;
				setTimeout(() => {
					if (this.#closed) return;
					this.#title(id, entry)
						.catch((error) => {
							if (!this.#closed) console.error(`[tau] title for conversation ${id} failed:`, error);
						})
						.finally(() => this.#pending.delete(id));
				}, 0);
			}
		});
	}

	close(): void {
		this.#closed = true;
		this.#unsubscribe();
	}

	async #title(id: ConversationId, answer: EntryRecord): Promise<void> {
		const context = BACKGROUND_CONTEXT;
		const { harness, models } = this.#host;
		const meta = await harness.snapshot(MetaDoc, id, context);
		if (meta?.autoTitle !== true) return;
		const handle = await harness.conversation(id, context);
		if (handle === undefined) return;
		const firstUser = [...(await handle.entries({}, 50, undefined, context)).items].reverse().find((entry) => entry.kind === "pi.user");
		// Photos alone: the answer says what they are.
		const question = text(firstUser?.model?.[0]) || (hasImage(firstUser?.model?.[0]) ? "(photos)" : "");
		const reply = text(answer.model?.[0]);
		if (question === "") return;
		const agent = await harness.snapshot(AgentDoc, id, context);
		const ref = agent?.model ?? this.#host.defaultModel;
		const model = models.getModel(ref.provider, ref.modelId);
		if (model === undefined) return;
		try {
			const result = await models.completeSimple(model, {
				systemPrompt: PROMPT,
				messages: [
					{ role: "user", content: `User: ${question.slice(0, 2000)}\n\nAssistant: ${reply.slice(0, 2000)}`, timestamp: Date.now() },
				],
			});
			const title = shorten(text(result).replace(/^["'#\s]+|["'.\s]+$/g, "").split("\n")[0] ?? "", 48);
			if (title === "") return;
			await harness.commit(async (tx) => {
				const doc = await tx.doc(MetaDoc, id);
				if (doc.autoTitle !== true) return;
				doc.title = title;
				doc.autoTitle = false;
			}, context);
		} catch (error) {
			console.error(`[tau] title for conversation ${id} failed:`, error);
		}
	}
}

function text(message: Message | AssistantMessage | undefined): string {
	if (message === undefined) return "";
	if (typeof message.content === "string") return message.content;
	return message.content
		.flatMap((part) => (part.type === "text" ? [part.text] : []))
		.join(" ")
		.trim();
}

function hasImage(message: Message | AssistantMessage | undefined): boolean {
	return message !== undefined && typeof message.content !== "string" && message.content.some((part) => part.type === "image");
}

/** At most `max` characters, cut at a word boundary. */
function shorten(title: string, max: number): string {
	if (title.length <= max) return title;
	const cut = title.slice(0, max + 1);
	const space = cut.lastIndexOf(" ");
	return (space > max / 2 ? cut.slice(0, space) : title.slice(0, max)).replace(/[,;:\s]+$/, "");
}
