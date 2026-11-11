import assert from "node:assert/strict";
import { test } from "node:test";
import { applyOps } from "../src/ops.ts";
import type { Json } from "../src/protocol.ts";

test("each op of docs/protocol.md, applied in order, without touching the input", () => {
	const docs: Json = { "pi.live": { generation: { message: { content: [{ type: "text", text: "Hel" }] } } }, list: [1, 2, 3] };
	const before = structuredClone(docs);
	const after = applyOps(docs, [
		["a", ["pi.live", "generation", "message", "content", 0, "text"], "lo"],
		["s", ["pi.live", "run"], { taskId: 7 }],
		["p", ["list"], 1, 1, [9, 8]],
		["m", ["list"], [3, 2, 1, 0]],
		["t", ["pi.live", "generation", "message", "content", 0, "text"], 2],
		["d", ["pi.live", "run"]],
	]);
	assert.deepEqual(after, { "pi.live": { generation: { message: { content: [{ type: "text", text: "llo" }] } } }, list: [3, 8, 9, 1] });
	assert.deepEqual(docs, before);
	assert.deepEqual(applyOps(docs, [["r", { fresh: true }]]), { fresh: true });
});
