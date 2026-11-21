// How fast a model answered: each response's final message gets `firstTokenMs`, the milliseconds from the request to
// the first text, thinking or tool call it streamed, on the same monotonic clock as pi-ai's `durationMs`. The clients
// show it, with tokens per second worked out from `durationMs` and the usage, under an answer (docs/protocol.md
// "Entries").
import type { AssistantMessage, AssistantMessageEvent, AssistantMessageEventStream, Models } from "@earendil-works/pi-ai";

type Timed = AssistantMessage & { firstTokenMs?: number };

const FIRST_TOKEN_EVENTS: ReadonlySet<AssistantMessageEvent["type"]> = new Set(["text_delta", "thinking_delta", "toolcall_delta"]);

/** `models` whose responses say when their first token came. */
export function timeFirstTokens(models: Models): Models {
	return new Proxy(models, {
		get: (target, property) => {
			if (property === "streamSimple") {
				return (...args: Parameters<Models["streamSimple"]>) => {
					const startedAt = performance.now();
					const events = target.streamSimple(...args);
					observe(events, startedAt);
					return events;
				};
			}
			const value = Reflect.get(target, property, target);
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
}

/** Times the stream's first token, without consuming it: the final message carries it as it is pushed. */
function observe(events: AssistantMessageEventStream, startedAt: number): void {
	let firstTokenMs: number | undefined;
	const push = events.push.bind(events);
	events.push = (event: AssistantMessageEvent) => {
		if (firstTokenMs === undefined && FIRST_TOKEN_EVENTS.has(event.type)) {
			firstTokenMs = Math.max(0, Math.round(performance.now() - startedAt));
		}
		if (event.type === "done" && firstTokenMs !== undefined) (event.message as Timed).firstTokenMs ??= firstTokenMs;
		push(event);
	};
}
