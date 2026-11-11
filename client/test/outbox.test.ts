import assert from "node:assert/strict";
import { test } from "node:test";
import { RequestError } from "../src/connection.ts";
import { Outbox, type OutboxState } from "../src/outbox.ts";

/** A server that holds every request until the test answers it, and a clock and timers the test moves. */
function harness(state?: OutboxState) {
	const requests: { method: string; params: any; resolve: (value: unknown) => void; reject: (error: Error) => void }[] = [];
	const client = {
		request: (method: string, params: any) => new Promise((resolve, reject) => requests.push({ method, params, resolve, reject })),
	};
	const timers: { ms: number; run: () => void }[] = [];
	const saved: OutboxState[] = [];
	const events: string[] = [];
	let ids = 0;
	const outbox = new Outbox({
		state,
		persist: (snapshot) => void saved.push(snapshot),
		newId: () => `r${++ids}`,
		now: () => 1000,
		delay: (ms, run) => void timers.push({ ms, run }),
		events: {
			restored: (id, text) => void events.push(`restored ${id} ${text}`),
			placed: (item, entry) => void events.push(`placed ${item.requestId} ${entry}`),
			notice: (id, text) => void events.push(`notice ${id} ${text}`),
			created: (create, id) => void events.push(`created ${create.requestId} ${id}`),
		},
	});
	const settle = () => new Promise((done) => setTimeout(done, 0));
	/** The oldest request not answered yet, once it is on the wire. */
	const next = async () => {
		await settle();
		const request = requests.shift();
		assert.ok(request, "a request went out");
		return request;
	};
	return { outbox, client, requests, timers, saved, events, settle, next };
}

const record = (fields: Record<string, unknown>) => ({ submission: { id: 7, conversationId: 1, ...fields } });

test("a message is persisted before its submit goes, and is placed when the entry comes", async () => {
	const { outbox, client, next, saved, events } = harness();
	outbox.connected(client, "db");
	const item = outbox.enqueue({ text: "hello", conversationId: 1 });
	const submit = await next();
	assert.equal(submit.method, "conversation.submit");
	assert.deepEqual(submit.params, { conversationId: 1, requestId: "r1", content: "hello", whenBusy: "steer" });
	assert.ok(saved.some((each) => each.items[0]?.wasSent), "written as sent before it went");
	submit.resolve(record({ requestId: "r1", status: "placed", entry: 12 }));
	await next().catch(() => undefined);
	assert.deepEqual(outbox.item(item.requestId)?.state, { type: "placed", entryId: 12 });
	assert.deepEqual(events, ["placed r1 12"]);
	assert.equal(outbox.placedAs(1, 12)?.requestId, "r1");
	outbox.settle("r1");
	assert.equal(outbox.items.length, 0);
});

test("one request per conversation at a time, in order; conversations go side by side", async () => {
	const { outbox, client, requests, settle } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "a", conversationId: 1 });
	outbox.enqueue({ text: "b", conversationId: 1 });
	outbox.enqueue({ text: "c", conversationId: 2 });
	await settle();
	assert.deepEqual(requests.map((each) => each.params.content), ["a", "c"]);
	requests.shift()!.resolve(record({ requestId: "r1", status: "queued" }));
	await settle();
	assert.deepEqual(requests.map((each) => each.params.content), ["c", "b"]);
	assert.deepEqual(outbox.item("r1")?.state, { type: "queued", submissionId: 7 });
	assert.equal(outbox.item("r1")?.showsInQueue, true);
});

test("a lost connection never fails a message: it goes again with the same request ID", async () => {
	const { outbox, client, next } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "hello", conversationId: 1 });
	const first = await next();
	outbox.disconnected();
	first.reject(new Error("connection closed"));
	await new Promise((done) => setTimeout(done, 0));
	assert.deepEqual(outbox.item("r1")?.state, { type: "pending" });
	outbox.connected(client, "db");
	const second = await next();
	assert.equal(second.params.requestId, "r1");
});

test("internal is retried 1, 2, 4 and 8 s apart, then the message fails; a refusal fails it at once", async () => {
	const { outbox, client, next, timers } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "hello", conversationId: 1 });
	for (const ms of [1000, 2000, 4000, 8000]) {
		(await next()).reject(new RequestError("internal", "boom"));
		await new Promise((done) => setTimeout(done, 0));
		assert.equal(timers.at(-1)?.ms, ms);
		timers.at(-1)!.run();
	}
	(await next()).reject(new RequestError("internal", "boom"));
	await new Promise((done) => setTimeout(done, 0));
	assert.deepEqual(outbox.item("r1")?.state, { type: "failed", code: "internal", message: "boom" });

	outbox.enqueue({ text: "again", conversationId: 2 });
	(await next()).reject(new RequestError("not_found", "no such conversation"));
	await new Promise((done) => setTimeout(done, 0));
	assert.deepEqual(outbox.item("r2")?.state, { type: "failed", code: "not_found", message: "This chat no longer exists" });
	assert.equal(outbox.discard("r2"), true);
});

test("a message over 1,000,000 characters fails without being sent", async () => {
	const { outbox, client, requests, settle } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "x".repeat(1_000_001), conversationId: 1 });
	await settle();
	assert.equal(requests.length, 0);
	assert.equal(outbox.item("r1")?.state.type, "failed");
});

test("withdrawing: dropped locally before it was sent, asked of the server after, restored when asked", async () => {
	const { outbox, client, next, requests, settle, events } = harness();
	outbox.enqueue({ text: "never sent", conversationId: 1 });
	assert.equal(outbox.withdraw("r1", { restore: true }), true);
	assert.equal(outbox.items.length, 0);
	assert.deepEqual(events, ["restored 1 never sent"]);

	outbox.connected(client, "db");
	outbox.enqueue({ text: "queued", conversationId: 1 });
	(await next()).resolve(record({ requestId: "r2", status: "queued" }));
	await settle();
	assert.equal(outbox.withdraw("r2", { restore: true }), true);
	const withdraw = await next();
	assert.deepEqual([withdraw.method, withdraw.params], ["submission.withdraw", { conversationId: 1, requestId: "r2" }]);
	withdraw.resolve({ result: "aborted" });
	await settle();
	assert.equal(outbox.items.length, 0);
	assert.deepEqual(events.at(-1), "restored 1 queued");
	assert.equal(requests.length, 0);
});

test("a withdraw that comes too late keeps the message as placed and says so", async () => {
	const { outbox, client, next, settle, events } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "late", conversationId: 1 });
	const submit = await next();
	outbox.withdraw("r1");
	submit.resolve(record({ requestId: "r1", status: "queued" }));
	const withdraw = await next();
	withdraw.resolve({ result: "already_placed", submission: { id: 7, entry: 30 } });
	await settle();
	assert.deepEqual(outbox.item("r1")?.state, { type: "placed", entryId: 30 });
	assert.deepEqual(events, ["placed r1 30", "notice 1 Already delivered"]);
});

test("moving a queued message: withdrawn, then sent anew with the other mode; dropped if the original got through", async () => {
	const { outbox, client, next, settle } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "move me", conversationId: 1 });
	(await next()).resolve(record({ requestId: "r1", status: "queued" }));
	await settle();
	outbox.move("r1", "followUp");
	(await next()).resolve({ result: "aborted" });
	const submit = await next();
	assert.deepEqual([submit.params.requestId, submit.params.whenBusy], ["r2", "followUp"]);

	outbox.enqueue({ text: "too late", conversationId: 2 });
	(await next()).resolve({ submission: { id: 8, requestId: "r3", status: "queued" } });
	await settle();
	outbox.move("r3", "followUp");
	(await next()).resolve({ result: "already_placed", submission: { id: 8, entry: 40 } });
	await settle();
	assert.equal(outbox.item("r4"), undefined, "no duplicate");
});

test("Stop withdraws the queued messages back to the field, then aborts", async () => {
	const { outbox, client, next, settle, events } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "one", conversationId: 1 });
	(await next()).resolve(record({ requestId: "r1", status: "queued" }));
	await settle();
	const stopped = outbox.interrupt(1, { restoring: ["r1"] });
	(await next()).resolve({ result: "aborted" });
	const abort = await next();
	assert.deepEqual([abort.method, abort.params], ["conversation.abort", { conversationId: 1 }]);
	abort.resolve({});
	await stopped;
	assert.deepEqual(events, ["restored 1 one"]);
});

test("a draft's messages wait for its create, which is idempotent and carries the agent", async () => {
	const { outbox, client, next, settle, events } = harness();
	outbox.connected(client, "db");
	outbox.enqueueCreate({ requestId: "draft", title: "New chat", agent: { thinkingLevel: "high" } });
	outbox.enqueue({ text: "first", createRequestId: "draft" });
	const configured = outbox.request("conversation.configure", { createRequestId: "draft" }, { agent: { thinkingLevel: "low" } });
	const create = await next();
	assert.deepEqual([create.method, create.params], [
		"conversation.create", { requestId: "draft", autoTitle: true, title: "New chat", agent: { thinkingLevel: "high" } },
	]);
	assert.equal(outbox.updateCreate("draft", { title: "late" }), false, "on the wire");
	create.reject(new Error("connection closed"));
	await settle();
	outbox.connected(client, "db");
	(await next()).resolve({ dialog: { conversation: { id: 5 } } });
	const submit = await next();
	assert.deepEqual([submit.params.conversationId, submit.params.content], [5, "first"]);
	submit.resolve(record({ requestId: "r1", status: "placed", entry: 2 }));
	const configure = await next();
	assert.deepEqual(configure.params, { agent: { thinkingLevel: "low" }, conversationId: 5 });
	configure.resolve({});
	await configured;
	assert.ok(events.includes("created draft 5"));
	assert.equal(outbox.enqueue({ text: "second", createRequestId: "draft" }).conversationId, 5);
});

test("entries match what is on its way before the records come, oldest first", async () => {
	const { outbox, client, next, settle } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "same", conversationId: 1 });
	outbox.enqueue({ text: "same", conversationId: 1 });
	(await next()).resolve(record({ id: 1, requestId: "r1", status: "queued" }));
	(await next()).resolve(record({ id: 2, requestId: "r2", status: "queued" }));
	await settle();
	outbox.matchPlacements(1, [{ id: 20, text: "same" }]);
	assert.deepEqual(outbox.item("r1")?.state, { type: "placed", entryId: 20 });
	assert.equal(outbox.item("r2")?.state.type, "queued");
	// A record that was overtaken does not move it back
	outbox.apply({ id: 1, requestId: "r1", status: "queued" });
	assert.equal(outbox.item("r1")?.state.type, "placed");
});

test("relaunched, queued messages ask again; another server database fails them", async () => {
	const first = harness();
	first.outbox.connected(first.client, "db");
	first.outbox.enqueue({ text: "queued", conversationId: 1 });
	(await first.next()).resolve(record({ requestId: "r1", status: "queued" }));
	await first.settle();
	const state = first.saved.at(-1)!;

	const again = harness(structuredClone(state));
	again.outbox.connected(again.client, "db");
	const refresh = await again.next();
	assert.equal(refresh.params.requestId, "r1");

	const replaced = harness(structuredClone(state));
	replaced.outbox.connected(replaced.client, "another db");
	await replaced.settle();
	assert.equal(replaced.requests.length, 0);
	assert.equal(replaced.outbox.item("r1")?.state.type, "failed");
});

test("a push from another device's Stop takes a queued message back to the field", async () => {
	const { outbox, client, next, settle, events } = harness();
	outbox.connected(client, "db");
	outbox.enqueue({ text: "queued", conversationId: 1 });
	(await next()).resolve(record({ requestId: "r1", status: "queued" }));
	await settle();
	outbox.apply({ id: 7, status: "unanswered", reason: "aborted" });
	assert.equal(outbox.items.length, 0);
	assert.deepEqual(events, ["restored 1 queued"]);
});
