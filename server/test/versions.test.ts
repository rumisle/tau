import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";
import { hiddenIn, type Span, subtract, union, type VersionsState } from "../src/versions.ts";

function until(replica: ConversationReplica, predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
	if (predicate()) return Promise.resolve();
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			stop();
			reject(new Error("timed out"));
		}, timeoutMs);
		const stop = replica.onChange(() => {
			if (!predicate()) return;
			clearTimeout(timer);
			stop();
			resolve();
		});
	});
}

const idle = (replica: ConversationReplica) => (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined;
const versions = (replica: ConversationReplica) => (replica.docs["tau.versions"] as VersionsState | undefined) ?? { groups: {}, hidden: [] };

function text(entry: Entry): string {
	const content = (entry.model as { content: string | { type: string; text?: string }[] }[] | undefined)?.[0]?.content;
	return typeof content === "string" ? content : (content ?? []).map((part) => part.text ?? "").join("");
}

/** What the chat shows: user messages and answers, without the versions not shown. */
function shown(replica: ConversationReplica): string[] {
	const hidden = versions(replica).hidden;
	return replica
		.ordered()
		.filter((entry) => (entry.kind === "pi.user" || entry.kind === "pi.assistant") && !hiddenIn(hidden, entry.id))
		.map((entry) => (entry.kind === "pi.user" ? `> ${text(entry)}` : (text(entry).match(/^You said: .*|\(turn \d+\)/gm) ?? []).join(" ")));
}

function userEntry(replica: ConversationReplica, content: string): Entry {
	const hidden = versions(replica).hidden;
	const found = replica.ordered().findLast((entry) => entry.kind === "pi.user" && text(entry) === content && !hiddenIn(hidden, entry.id));
	assert.ok(found, `no message ${content}`);
	return found;
}

describe("versions: spans", () => {
	test("union joins, subtract cuts, hiddenIn finds", () => {
		const spans: Span[] = union([[1, 3]], [[7, 9], [4, 5]]);
		assert.deepEqual(spans, [[1, 5], [7, 9]]);
		assert.deepEqual(subtract([[1, 20]], spans), [[6, 6], [10, 20]]);
		assert.equal(hiddenIn(spans, 8), true);
		assert.equal(hiddenIn(spans, 6), false);
	});
});

describe("edits in place", () => {
	let host: Host;
	let server: Server;
	let client: TauClient;
	before(async () => {
		host = await openHost({ devTokensPerSecond: 2_000, cwd: tmpdir() });
		server = await serve(host);
		client = await TauClient.connect(server.url);
	});
	after(async () => {
		await client.close();
		await server.close();
		await host.close();
	});

	async function chat(): Promise<ConversationReplica> {
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		return replica;
	}
	async function say(replica: ConversationReplica, content: string, requestId: string, edit?: number): Promise<void> {
		await client.request("conversation.submit", { conversationId: replica.id, requestId, content, ...(edit === undefined ? {} : { edit }) });
		await until(replica, () => idle(replica) && replica.ordered().some((entry) => entry.kind === "pi.assistant" && text(entry).startsWith(`You said: ${content}`)));
	}

	test("an edit goes on in the same chat from the new text: the model no longer reads what came after", async () => {
		const replica = await chat();
		await say(replica, "one", "e1");
		await say(replica, "two", "e2");
		await say(replica, "two, better", "e3", userEntry(replica, "two").id);
		assert.deepEqual(shown(replica), ["> one", "You said: one (turn 1)", "> two, better", "You said: two, better (turn 2)"]);
		const group = Object.values(versions(replica).groups)[0]!;
		assert.deepEqual(group.versions.map((version) => version.text), ["two", "two, better"]);
		assert.equal(group.current, 1);
		assert.match(group.versions[0]!.answer ?? "", /^You said: two/);

		// The first message too: one chat still, the model reads only the new text.
		await say(replica, "uno", "e4", userEntry(replica, "one").id);
		assert.deepEqual(shown(replica), ["> uno", "You said: uno (turn 1)"]);
		const { dialogs } = await client.request("dialogs.subscribe", {});
		assert.equal(dialogs.filter((dialog: { conversation: { id: number } }) => dialog.conversation.id === replica.id).length, 1);
		const listed = dialogs.find((dialog: { conversation: { id: number } }) => dialog.conversation.id === replica.id);
		assert.match(listed.last.text, /^You said: uno/, "the list shows the version shown");
	});

	test("a repeated edit (a lost response) makes one version", async () => {
		const replica = await chat();
		await say(replica, "alpha", "r1");
		const message = userEntry(replica, "alpha").id;
		await say(replica, "beta", "r2", message);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "r2", content: "beta", edit: message });
		await new Promise((resolve) => setTimeout(resolve, 300));
		assert.equal(Object.values(versions(replica).groups)[0]!.versions.length, 2);
		assert.deepEqual(shown(replica), ["> beta", "You said: beta (turn 1)"]);
	});

	test("switching back shows the earlier version as it was, and the model reads it again", async () => {
		const replica = await chat();
		await say(replica, "first", "s1");
		await say(replica, "second", "s2");
		await say(replica, "second, again", "s3", userEntry(replica, "second").id);
		const group = Object.values(versions(replica).groups)[0]!;
		await client.request("conversation.version", { conversationId: replica.id, message: group.versions[0]!.message });
		await until(replica, () => Object.values(versions(replica).groups)[0]!.current === 0);
		assert.deepEqual(shown(replica), ["> first", "You said: first (turn 1)", "> second", "You said: second (turn 2)"]);
		await say(replica, "third", "s4");
		assert.deepEqual(shown(replica).slice(-1), ["You said: third (turn 3)"]);
		// And forward again: the later version, without what the earlier one went on with.
		await client.request("conversation.version", { conversationId: replica.id, message: group.versions[1]!.message });
		await until(replica, () => Object.values(versions(replica).groups)[0]!.current === 1);
		assert.deepEqual(shown(replica), ["> first", "You said: first (turn 1)", "> second, again", "You said: second, again (turn 2)"]);
		await say(replica, "fourth", "s5");
		assert.deepEqual(shown(replica).slice(-1), ["You said: fourth (turn 3)"]);
	});

	test("an edit while the chat works stops it first", async () => {
		const replica = await chat();
		await say(replica, "start", "b1");
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "b2", content: "~3 slow" });
		await until(replica, () => !idle(replica));
		await say(replica, "quick", "b3", userEntry(replica, "~3 slow").id);
		assert.deepEqual(shown(replica), ["> start", "You said: start (turn 1)", "> quick", "You said: quick (turn 2)"]);
	});

	test("an edit older than the context's summary is refused, for the client to fork", async () => {
		const replica = await chat();
		await say(replica, "old", "c1");
		await say(replica, "newer", "c2");
		await client.request("conversation.compact", { conversationId: replica.id });
		await until(replica, () => replica.ordered().some((entry) => entry.kind === "pi.compaction") && idle(replica), 20_000);
		await assert.rejects(
			client.request("conversation.submit", { conversationId: replica.id, requestId: "c3", content: "edited", edit: userEntry(replica, "old").id }),
			/before_summary|summary/,
		);
	});
});
