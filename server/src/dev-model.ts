// A free scripted model for development: streams an echo of each message, runs `$ <command>` through bash, and starts
// a background subagent for `& <name> [fork] [model=…] [thinking=…]: <task>`, waits before answering `~<seconds> <text>`,
// fails as an overloaded provider would `!overloaded <times> <text>` before answering, and fails for good `!fatal <text>`.
// `!read <path>` reads a file with the read tool (an image comes back as one). `!doc <sections>` streams a long Markdown answer (headings, paragraphs, lists, code, tables, math), to read while it
// streams. With a cache lifetime (`--dev-cache-ttl <seconds>`) it charges as a costly model whose prompt cache expires
// that long after it was last used, to try cache warming (src/cache.ts) without paying for it.
import { type Api, calculateCost, createAssistantMessageEventStream, type AssistantMessage, type Message, type Model, type Provider } from "@earendil-works/pi-ai";
import {
	type FauxProviderHandle,
	type FauxResponseFactory,
	fauxAssistantMessage,
	fauxProvider,
	fauxText,
	fauxThinking,
	fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";

export const DEV_MODEL = { provider: "dev", modelId: "echo" } as const;

/** Errors made so far for each `!overloaded` message. */
const failures = new Map<string, number>();

/** Per million tokens: four times Claude Opus, so that warming the dev model's small prompts (a thousand tokens) pays. */
const CACHED_COST = { input: 60, output: 300, cacheRead: 6, cacheWrite: 75 };

export function devProvider(options: { tokensPerSecond?: number; cacheTtl?: number } = {}): { provider: Provider } & Omit<FauxProviderHandle, "provider"> {
	const faux = fauxProvider({
		provider: DEV_MODEL.provider,
		models: [{ id: DEV_MODEL.modelId, name: "Dev echo", reasoning: true, contextWindow: 200_000, maxTokens: 8_192, ...(options.cacheTtl === undefined ? {} : { cost: CACHED_COST }) }],
		tokensPerSecond: options.tokensPerSecond ?? 80,
	});
	// Faux responses are consumed one per request; this one queues itself again so the model never runs dry.
	const respond: FauxResponseFactory = async (context) => {
		faux.appendResponses([respond]);
		// `~<seconds> ` first: a model slow to start answering.
		const last = context.messages.findLast((message) => (message.role as string) !== "system");
		const wait = last?.role === "user" ? /^~(\d+(?:\.\d+)?) /.exec(userText(last.content)) : null;
		if (wait !== null) await new Promise((resolve) => setTimeout(resolve, Number(wait[1]) * 1000));
		// A compaction's summarization: a few seconds, and a summary shaped like a real one.
		if (context.messages.some((message) => (message.role as string) === "system" && JSON.stringify(message).includes("summarization assistant"))) {
			await new Promise((resolve) => setTimeout(resolve, 3000));
			const turns = context.messages.filter((message) => message.role === "user").length;
			return fauxAssistantMessage([fauxText(`## Goal\nTry tau's compaction with the dev model.\n\n## Progress\n- ${turns} messages summarized\n- The echo model answered each one\n\n## Next Steps\n1. Keep chatting after the summary`)]);
		}
		// Provider errors: retried ones a number of times for this message, then the answer; a final one at once.
		const text = last?.role === "user" ? userText(last.content) : "";
		const overloaded = /^!overloaded (\d+) /.exec(text);
		if (overloaded !== null && last?.role === "user") {
			const key = `${text}@${last.timestamp}`;
			const failed = failures.get(key) ?? 0;
			if (failed < Number(overloaded[1])) {
				failures.set(key, failed + 1);
				return fauxAssistantMessage([], { stopReason: "error", errorMessage: '529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' });
			}
		}
		if (text.startsWith("!fatal ")) {
			return fauxAssistantMessage([fauxText("Let me look")], { stopReason: "error", errorMessage: '401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' });
		}
		return reply(context.messages);
	};
	faux.setResponses([respond]);
	if (options.cacheTtl === undefined) return faux;
	faux.models[0].promptCache = { short: options.cacheTtl };
	return { ...faux, provider: expiringCache(faux.provider, options.cacheTtl * 1000) };
}

/**
 * The faux provider's cache never expires and costs nothing: this one forgets a session's prompt `ttl` after its last
 * request, caps the output at `maxTokens` as a provider would, and prices the usage.
 */
function expiringCache(base: Provider, ttl: number): Provider {
	const used = new Map<string, number>();
	const adjust = (model: Model<Api>, message: AssistantMessage, expired: boolean, maxTokens: number | undefined): void => {
		const usage = message.usage;
		if (expired) {
			usage.cacheWrite += usage.cacheRead;
			usage.cacheRead = 0;
		}
		if (maxTokens !== undefined) usage.output = Math.min(usage.output, maxTokens);
		usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
		usage.cost = calculateCost(model, usage);
	};
	return {
		...base,
		streamSimple(model, context, streamOptions) {
			const session = streamOptions?.sessionId;
			const now = Date.now();
			const expired = session === undefined || now - (used.get(session) ?? Number.NEGATIVE_INFINITY) > ttl;
			if (session !== undefined) used.set(session, now);
			const outer = createAssistantMessageEventStream();
			// A cap of a few tokens, as a cache refresh sends: a real provider stops at once, after reading the prompt.
			const cap = streamOptions?.maxTokens;
			if (cap !== undefined && cap <= 16) {
				const prompt = Math.ceil(context.messages.map((message) => JSON.stringify(message.content)).join("").length / 4);
				const usage = { input: 0, output: cap, cacheRead: expired ? 0 : prompt, cacheWrite: expired ? prompt : 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
				const message: AssistantMessage = { role: "assistant", content: [{ type: "text", text: "." }], api: model.api, provider: model.provider, model: model.id, usage, stopReason: "length", timestamp: now };
				adjust(model, message, false, cap);
				queueMicrotask(() => outer.push({ type: "done", reason: "length", message }));
				return outer;
			}
			const inner = base.streamSimple(model, context, streamOptions);
			void (async () => {
				for await (const event of inner) {
					if (event.type === "done") adjust(model, event.message, expired, streamOptions?.maxTokens);
					else if (event.type === "error") adjust(model, event.error, expired, streamOptions?.maxTokens);
					outer.push(event);
				}
				outer.end(await inner.result());
			})();
			return outer;
		},
	};
}

function reply(messages: readonly Message[]) {
	// System messages carry prompt changes; the request is about the message before them.
	const last = messages.findLast((message) => (message.role as string) !== "system");
	if (last?.role === "toolResult") {
		const output = last.content.map((part) => (part.type === "text" ? part.text : `[${part.type}]`)).join("");
		return fauxAssistantMessage([fauxText(`Ran it${last.isError ? " (it failed)" : ""}:\n\n\`\`\`\n${output.trimEnd()}\n\`\`\``)]);
	}
	const text = last?.role === "user" ? userText(last.content) : "";
	if (text.startsWith("$ ")) {
		return fauxAssistantMessage([fauxToolCall("bash", { command: text.slice(2) })], { stopReason: "toolUse" });
	}
	if (text.startsWith("!read ")) {
		return fauxAssistantMessage([fauxToolCall("read", { path: text.slice(6).trim() })], { stopReason: "toolUse" });
	}
	// `& name fork model=dev/echo thinking=high: task`, each option optional.
	const subagent = /^& ([\w-]+)((?: [\w=./-]+)*): ([\s\S]+)$/.exec(text);
	if (subagent !== null) {
		const options: Record<string, unknown> = {};
		for (const option of subagent[2]!.trim().split(" ").filter((each) => each !== "")) {
			const [key, value] = option.split("=");
			options[key!] = value ?? true;
		}
		return fauxAssistantMessage([fauxToolCall("subagent", { action: "spawn", name: subagent[1]!, message: subagent[3]!, ...options })], { stopReason: "toolUse" });
	}
	const doc = /^!doc (\d+)/.exec(text);
	if (doc !== null) return fauxAssistantMessage([fauxText(longDocument(Number(doc[1])))]);
	const turns = messages.filter((message) => message.role === "user").length;
	return fauxAssistantMessage([
		fauxThinking(`The user said ${JSON.stringify(text)}. Turn ${turns}.`),
		fauxText(`You said: ${text}\n\nThis is the dev echo model (turn ${turns}). Start a message with \`$ \` to run a shell command.`),
	]);
}

function userText(content: Extract<Message, { role: "user" }>["content"]): string {
	if (typeof content === "string") return content;
	return content.map((part) => (part.type === "text" ? part.text : "[image]")).join("");
}

/** A long answer of every kind of block, `sections` times over, numbered so a screen shows where it is. */
export function longDocument(sections: number): string {
	const parts: string[] = [];
	for (let index = 1; index <= sections; index++) {
		parts.push(`## Section ${index}`);
		parts.push(
			`Paragraph ${index}.1: the server commits each step of the run before showing it, so a restart picks up where it stopped. ` +
				`This sentence is long enough to wrap over several lines on a phone, which is the point of it.`,
		);
		parts.push(`- point ${index}.a, short\n- point ${index}.b, a little longer than the first one\n- point ${index}.c`);
		if (index % 2 === 1) {
			parts.push("```swift\nfunc section" + index + "() -> Int {\n    let value = " + index + " * 2\n    return value + 1\n}\n```");
		} else {
			parts.push(`| Name | Value |\n| --- | --- |\n| alpha ${index} | ${index * 3} |\n| beta ${index} | ${index * 5} |`);
		}
		parts.push(`Paragraph ${index}.2 ends the section with $e^{i\\pi} + 1 = 0$ inline and one more line of text after it.`);
	}
	return parts.join("\n\n");
}
