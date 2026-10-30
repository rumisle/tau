// The text history shows of an entry's parts (docs/history.md): what the search index indexes and what history_read
// reads are cut from the same strings, so an excerpt, an exact match and a read agree. And the truncation of a part,
// after durable's truncate.ts (lines and bytes, whole lines), which has no tail variant and is not exported.
import type { Message } from "@earendil-works/pi-ai";
import { ownText } from "./attachments.ts";

export type HistoryKind = "user" | "assistant" | "reasoning" | "tool_call" | "tool_output" | "title";
export const HISTORY_KINDS: readonly HistoryKind[] = ["user", "assistant", "reasoning", "tool_call", "tool_output", "title"];

/** The argument a tool's card titles it by: bash's command, read's path; the first string argument otherwise. */
const PRIMARY = ["command", "path", "code", "query", "message", "paths", "link", "url", "pattern"];

/**
 * A tool call as text: the tool's name, a colon, the argument its card titles it by, then the other arguments as
 * `key: value` lines. `bash: npm run build`; `edit: src/a.ts` with its old and new text after.
 */
export function toolCallText(name: string, args: unknown): string {
	if (typeof args !== "object" || args === null) return name;
	const entries = Object.entries(args as Record<string, unknown>);
	const primary = PRIMARY.find((key) => entries.some(([each]) => each === key)) ?? entries.find(([, value]) => typeof value === "string")?.[0];
	const show = (value: unknown) => (typeof value === "string" ? value : JSON.stringify(value));
	const head = primary === undefined ? name : `${name}: ${show((args as Record<string, unknown>)[primary])}`;
	const rest = entries.filter(([key, value]) => key !== primary && value !== undefined).map(([key, value]) => `${key}: ${show(value)}`);
	return [head, ...rest].join("\n");
}

/** A tool result's text: its text blocks, an image as [image]. */
export function toolOutputText(message: Message | undefined): string {
	if (message?.role !== "toolResult") return "";
	// Without the newline a command's output ends with, which would end it in an empty line.
	return message.content.map((part) => (part.type === "text" ? part.text : "[image]")).join("\n").replace(/\n+$/, "");
}

/** What the index keeps of a tool's output: its first and last 2 KB, where headers and errors are. */
export const OUTPUT_EDGE = 2048;
export function indexedOutputText(text: string): string {
	if (text.length <= OUTPUT_EDGE * 2) return text;
	return `${text.slice(0, OUTPUT_EDGE)}\n…\n${text.slice(-OUTPUT_EDGE)}`;
}

/** A user message's text, without its attachments block, and how many images it carries. */
export function userText(message: Extract<Message, { role: "user" }>): { text: string; images: number } {
	const content = message.content;
	const images = typeof content === "string" ? 0 : content.filter((part) => part.type === "image").length;
	return { text: ownText(content), images };
}

export type Cut = {
	text: string;
	/** What the whole had, when it was cut. */
	truncated?: { lines: number; bytes: number };
	/** The 1-based line to read on from, when the cut kept the start. */
	nextLine?: number;
};

const bytes = (text: string) => Buffer.byteLength(text, "utf8");

/**
 * Whole lines of `text` within `maxLines` and `maxBytes`: from line `offset` (1-based) on, or the last ones (`tail`,
 * as bash keeps a command's end). A first line longer than the bytes is cut inside, as nothing else would show.
 */
export function cut(text: string, options: { maxLines: number; maxBytes: number; tail?: boolean; offset?: number }): Cut {
	const all = text.split("\n");
	const offset = Math.max(1, options.offset ?? 1);
	const lines = options.tail === true ? all : all.slice(offset - 1);
	const total = { lines: all.length, bytes: bytes(text) };
	if (offset === 1 && lines.length <= options.maxLines && total.bytes <= options.maxBytes) return { text };
	const kept: string[] = [];
	let size = 0;
	const order = options.tail === true ? [...lines].reverse() : lines;
	for (const line of order) {
		if (kept.length >= options.maxLines) break;
		const add = bytes(line) + (kept.length > 0 ? 1 : 0);
		if (size + add > options.maxBytes) {
			if (kept.length === 0) {
				// One line longer than the limit: its part that fits.
				let piece = options.tail === true ? line.slice(-options.maxBytes) : line.slice(0, options.maxBytes);
				while (bytes(piece) > options.maxBytes) piece = options.tail === true ? piece.slice(1) : piece.slice(0, -1);
				kept.push(piece);
			}
			break;
		}
		kept.push(line);
		size += add;
	}
	if (options.tail === true) {
		kept.reverse();
		if (kept.length === all.length && kept.join("\n") === text) return { text };
		return { text: kept.join("\n"), truncated: total };
	}
	const next = offset + kept.length;
	if (offset === 1 && next > all.length && kept.join("\n") === text) return { text };
	return { text: kept.join("\n"), truncated: total, ...(next <= all.length ? { nextLine: next } : {}) };
}
