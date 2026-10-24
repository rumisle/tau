// What clients get of entries and docs: what they show. Left out are the provider's replay data (the signatures that
// let a model continue its own reasoning: opaque, near incompressible, and in a reasoning model's transcript about
// half of what history weighs) and a pi.system entry's prompt and tools, which no client shows; images go by reference
// (src/media.ts). The model's context keeps everything: this is only the wire. See docs/protocol.md.
import type { Op } from "@earendil-works/chord/delta";
import type { EntryRecord } from "@earendil-works/pi-durable";
import { withMediaRefs } from "./media.ts";

/** Keys of content blocks only the provider reads back. */
const REPLAY_KEYS: ReadonlySet<string> = new Set(["thinkingSignature", "textSignature", "thoughtSignature"]);

/** An entry as clients take it. */
export function clientEntry(entry: EntryRecord): EntryRecord {
	// The system prompt and tools as the model was given them: a client needs only that the entry is there.
	if (entry.kind === "pi.system") {
		const { model: _model, ...rest } = entry;
		return rest as EntryRecord;
	}
	return withoutReplay(withMediaRefs(entry));
}

/** Docs (a subscribe's snapshot, a resync) as clients take them: a streaming message's replay data left out. */
export function clientDocs<T>(docs: T): T {
	return withoutReplay(docs);
}

/** A doc op as clients take it; undefined when it only writes replay data. */
export function clientOp(op: Op): Op | undefined {
	if (op[0] !== "r" && op[1].some((key) => typeof key === "string" && REPLAY_KEYS.has(key))) return undefined;
	switch (op[0]) {
		case "r":
		case "s":
			return op[0] === "r" ? ["r", withoutReplay(op[1])] : ["s", op[1], withoutReplay(op[2])];
		case "p":
			return ["p", op[1], op[2], op[3], withoutReplay(op[4])];
		default:
			return op;
	}
}

/** `value` without replay keys at any depth; the same object where it has none, so nothing is copied for nothing. */
function withoutReplay<T>(value: T): T {
	if (typeof value !== "object" || value === null) return value;
	if (Array.isArray(value)) {
		let copy: unknown[] | undefined;
		for (let index = 0; index < value.length; index++) {
			const item = withoutReplay(value[index]);
			if (item !== value[index]) (copy ??= [...value])[index] = item;
		}
		return (copy ?? value) as T;
	}
	const object = value as Record<string, unknown>;
	let copy: Record<string, unknown> | undefined;
	for (const [key, item] of Object.entries(object)) {
		if (REPLAY_KEYS.has(key)) {
			copy ??= { ...object };
			delete copy[key];
			continue;
		}
		const stripped = withoutReplay(item);
		if (stripped !== item) (copy ??= { ...object })[key] = stripped;
	}
	return (copy ?? value) as T;
}
