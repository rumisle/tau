// A free scripted model for development: streams an echo of each message, and runs `$ <command>` through bash.
import type { Message } from "@earendil-works/pi-ai";
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

export function devProvider(options: { tokensPerSecond?: number } = {}): FauxProviderHandle {
	const faux = fauxProvider({
		provider: DEV_MODEL.provider,
		models: [{ id: DEV_MODEL.modelId, name: "Dev echo", reasoning: true, contextWindow: 200_000, maxTokens: 8_192 }],
		tokensPerSecond: options.tokensPerSecond ?? 80,
	});
	// Faux responses are consumed one per request; this one queues itself again so the model never runs dry.
	const respond: FauxResponseFactory = (context) => {
		faux.appendResponses([respond]);
		return reply(context.messages);
	};
	faux.setResponses([respond]);
	return faux;
}

function reply(messages: readonly Message[]) {
	const last = messages.at(-1);
	if (last?.role === "toolResult") {
		const output = last.content.map((part) => (part.type === "text" ? part.text : `[${part.type}]`)).join("");
		return fauxAssistantMessage([fauxText(`Ran it${last.isError ? " (it failed)" : ""}:\n\n\`\`\`\n${output.trimEnd()}\n\`\`\``)]);
	}
	const text = last?.role === "user" ? userText(last.content) : "";
	if (text.startsWith("$ ")) {
		return fauxAssistantMessage([fauxToolCall("bash", { command: text.slice(2) })], { stopReason: "toolUse" });
	}
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
