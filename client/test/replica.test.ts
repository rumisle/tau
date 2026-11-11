import assert from "node:assert/strict";
import { test } from "node:test";
import type { TauClient } from "../src/connection.ts";
import type { Entry, Push } from "../src/protocol.ts";
import { ConversationReplica } from "../src/replica.ts";
import { DialogList } from "../src/dialogs.ts";

/** A server in memory: answers requests from `handlers`, pushes when told. */
function fakeClient(handlers: Record<string, (params: any) => unknown>) {
	const listeners = new Set<(push: Push) => void>();
	const requests: { method: string; params: any }[] = [];
	const client = {
		request: async (method: string, params: any) => {
			requests.push({ method, params });
			return handlers[method]!(params);
		},
		on: (listener: (push: Push) => void) => {
			listeners.add(listener);
			return () => listeners.delete(listener);
		},
	};
	return { client: client as unknown as TauClient, requests, push: (push: Push) => listeners.forEach((listener) => listener(push)) };
}

const entry = (id: number): Entry => ({ id, kind: "pi.user", conversationId: 1 });

test("a replica subscribes after its newest entry, keeps a gap as a hole, fills it, and applies commits", async () => {
	const replica = new ConversationReplica(1);
	const server = fakeClient({
		"conversation.subscribe": () => ({ conversation: { id: 1 }, docs: { "pi.live": {} }, entries: [entry(50), entry(60)], hasOlder: true, gap: { after: 10, before: 50 }, submissions: [] }),
		"conversation.history": () => ({ entries: [entry(20), entry(30)], hasOlder: false }),
	});
	for (const id of [5, 10]) replica.entries.set(id, entry(id));
	await replica.sync(server.client);
	assert.equal(server.requests[0]!.params.after, 10);
	assert.deepEqual(replica.holes, [{ after: 10, before: 50 }]);
	await replica.fillHole(server.client);
	assert.deepEqual(replica.holes, []);
	assert.deepEqual(replica.ordered().map((each) => each.id), [5, 10, 20, 30, 50, 60]);

	server.push({ event: "conv.commit", conversationId: 1, ops: [["s", ["pi.live", "run"], { taskId: 3 }]], entries: [entry(70), entry(60)] });
	assert.deepEqual(replica.docs, { "pi.live": { run: { taskId: 3 } } });
	assert.equal(replica.maxId, 70);
	server.push({ event: "conv.commit", conversationId: 2, entries: [{ id: 80, kind: "pi.user", conversationId: 2 }] });
	assert.equal(replica.maxId, 70);
});

test("the chat list asks for what changed since its version, and starts over when the server restarted", async () => {
	const dialog = (id: number, title: string) => ({ conversation: { id }, title, agent: {}, busy: false, unreadCount: 0 });
	const list = DialogList.restore([dialog(1, "old"), dialog(2, "kept")], "v5");
	const changed: string[] = [];
	list.onChange((dialogs) => changed.push(...dialogs.map((each) => each.title!)));
	const server = fakeClient({ "dialogs.subscribe": () => ({ dialogs: [dialog(1, "new")], version: "v6", full: false }) });
	await list.sync(server.client);
	assert.deepEqual(server.requests[0]!.params, { since: "v5" });
	assert.deepEqual([...list.dialogs.values()].map((each) => each.title), ["new", "kept"]);
	server.push({ event: "dialog", dialog: dialog(3, "pushed"), version: "v7" });
	assert.equal(list.version, "v7");
	assert.deepEqual(changed, ["new", "pushed"]);

	const restarted = fakeClient({ "dialogs.subscribe": () => ({ dialogs: [dialog(9, "only")], version: "w1", full: true }) });
	await list.sync(restarted.client);
	assert.deepEqual([...list.dialogs.keys()], [9]);
});
