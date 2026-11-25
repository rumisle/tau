// A model provider from outside tau, as `--provider` loads it (src/external-providers.ts), for
// test/external-providers.test.ts and the web client's end-to-end tests: a gateway whose catalog is asked with the key,
// one chat model that echoes what it was asked and with which key, and its keys' usage: a budget with a limit and the
// month's spend without one. A key "bad-usage" answers a malformed report, "slow-usage" never answers. It imports pi-ai
// as any provider file does; its default export makes it a pi extension too, which tau leaves alone.
import { type AssistantMessage, createAssistantMessageEventStream, createProvider, type Model, type Api } from "@earendil-works/pi-ai";

const PROVIDER = "fixture-gateway";

function echo(model: Model<Api>, context: { messages: { role: string; content: unknown }[] }, options?: { apiKey?: string; headers?: Record<string, string> }) {
	const stream = createAssistantMessageEventStream();
	const last = context.messages.findLast((message) => message.role === "user");
	const asked = typeof last?.content === "string" ? last.content : JSON.stringify(last?.content ?? "");
	const text = `Gateway heard ${asked} with ${options?.headers?.["x-gateway-key"] ?? options?.apiKey ?? "no key"}`;
	const zero = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 };
	const message: AssistantMessage = {
		role: "assistant",
		content: [],
		api: model.api,
		provider: model.provider,
		model: model.id,
		usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15, cost: zero },
		stopReason: "stop",
		timestamp: Date.now(),
	};
	queueMicrotask(() => {
		stream.push({ type: "start", partial: message });
		message.content = [{ type: "text", text: "" }];
		stream.push({ type: "text_start", contentIndex: 0, partial: message });
		message.content = [{ type: "text", text }];
		stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: message });
		stream.push({ type: "text_end", contentIndex: 0, content: text, partial: message });
		stream.push({ type: "done", reason: "stop", message });
		stream.end(message);
	});
	return stream;
}

export const provider = createProvider({
	id: PROVIDER,
	name: "Fixture Gateway",
	auth: {
		apiKey: {
			name: "Fixture Gateway key",
			async login(interaction) {
				return { type: "api_key", key: await interaction.prompt({ type: "secret", message: "Enter the gateway key" }) };
			},
			// The gateway's key goes in a header of its own.
			async resolve({ credential }) {
				return credential?.key === undefined ? undefined : { auth: { apiKey: credential.key, headers: { "x-gateway-key": credential.key } } };
			},
		},
	},
	models: [],
	// The catalog comes from the gateway, with the key: none without one.
	async fetchModels(context) {
		if (context.credential?.type !== "api_key" || context.credential.key === undefined) return [];
		return [
			{
				id: "gateway-chat",
				name: "Gateway chat",
				api: "fixture-gateway-chat",
				provider: PROVIDER,
				baseUrl: "https://gateway.invalid",
				reasoning: false,
				input: ["text"],
				cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 100_000,
				maxTokens: 4_096,
			},
		];
	},
	api: { stream: echo as never, streamSimple: echo as never },
});

/** The first of next month, UTC: when a month's budget and spend start again. */
export function nextMonth(now = new Date()): number {
	return Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1);
}

export const usage = {
	async apiKey(key: string, context: { fetch: typeof fetch; signal: AbortSignal }) {
		if (key === "bad-usage") return { windows: [{ id: "month", label: "Month" }] };
		if (key === "slow-usage") {
			await new Promise((_, reject) => context.signal.addEventListener("abort", () => reject(context.signal.reason)));
		}
		return {
			windows: [
				{ id: "budget", label: "Budget", title: "Monthly Budget", usedPercent: 25, amount: "$25.00 of $100.00 spent", resetsAt: nextMonth(), seconds: 2_592_000 },
				{ id: "month", label: "Month", title: "This Month", amount: "$2,383.76 spent", resetsAt: nextMonth(), seconds: 2_592_000 },
			],
		};
	},
};

/** As a pi extension: pi calls this with its API. */
export default function (pi: { registerProvider(provider: unknown): void }) {
	pi.registerProvider(provider);
}
