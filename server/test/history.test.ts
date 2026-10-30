import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { after, before, describe, test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ConversationId } from "@earendil-works/pi-durable";
import { ConversationReplica, TauClient } from "../src/client.ts";
import { History, type ReadArgs, type ReadResult } from "../src/history.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";

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

describe("history", () => {
	let host: Host;
	let server: Server;
	let client: TauClient;
	let history: History;

	async function chat(title?: string): Promise<ConversationReplica> {
		const { dialog } = await client.request("conversation.create", title === undefined ? {} : { title });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		return replica;
	}

	async function say(replica: ConversationReplica, content: string): Promise<void> {
		const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: `${replica.id}-${content.slice(0, 40)}-${Math.random()}`, content });
		await until(replica, () => replica.submissions.get(submission.id)?.status === "done" && idle(replica));
	}

	const read = (caller: number, args: ReadArgs): Promise<ReadResult> => history.read(caller as ConversationId, args, BACKGROUND_CONTEXT);

	before(async () => {
		host = await openHost({ devTokensPerSecond: 4_000, cwd: tmpdir() });
		server = await serve(host);
		client = await TauClient.connect(server.url);
		history = new History(() => ({ harness: host.harness, storage: host.storage, serverId: host.serverId }));
	});
	after(async () => {
		await client.close();
		await server.close();
		await host.close();
	});

	test("read: a chat's newest entries, a call with its result, an entry alone, and paging up until it ends", async () => {
		const replica = await chat("Reading");
		for (let index = 1; index <= 8; index++) await say(replica, `message number ${index}`);
		await say(replica, "$ printf 'first\\nsecond\\n'");
		const latest = await read(replica.id, {});
		assert.equal(latest.chat.title, "Reading");
		assert.equal(latest.chat.link, history.link(replica.id));
		assert.equal(latest.chat.status, "idle");
		assert.equal(latest.entries.length, 10);
		assert.equal(latest.newer, null);
		// The call and its output in one entry, the answer after it.
		const call = latest.entries.find((entry) => entry.parts.some((part) => part.kind === "tool_call"))!;
		assert.deepEqual(call.parts.map((part) => part.kind), ["tool_call", "tool_output"]);
		assert.equal(call.parts[0]!.text, "bash: printf 'first\\nsecond\\n'");
		assert.match(call.parts[1]!.text, /first\nsecond/);
		assert.ok(latest.entries.every((entry) => entry.inContext === true), "its own chat: in context");
		// Paging up by `older` until it ends: every entry once, in order.
		const seen = latest.entries.map((entry) => entry.id);
		let older = latest.older;
		while (older !== null) {
			const page = await read(replica.id, older);
			seen.unshift(...page.entries.map((entry) => entry.id));
			older = page.older;
		}
		assert.deepEqual(seen, [...seen].sort((a, b) => a - b));
		assert.equal(new Set(seen).size, seen.length);
		assert.equal(seen.length, 8 * 2 + 3, "8 exchanges, then the call, its answer, and the message");
		// An entry: it and three each side; a result's own link reads as its call's.
		const middle = await read(replica.id, { link: history.link(replica.id, seen[8]!) });
		assert.deepEqual(middle.entries.map((entry) => entry.id), seen.slice(5, 12));
		const result = replica.ordered().find((entry) => entry.kind === "pi.tool-result")!;
		const alone = await read(replica.id, { link: history.link(replica.id, result.id), older: 0, newer: 0 });
		assert.deepEqual(alone.entries.map((entry) => entry.id), [call.id]);
		// The dialogue only.
		const dialogue = await read(replica.id, { kinds: ["user", "assistant"] });
		assert.ok(dialogue.entries.every((entry) => entry.parts.every((part) => part.kind === "user" || part.kind === "assistant")));
	});

	test("read: a long part is cut with next, which reads it on; truncate: false gives it whole", async () => {
		const replica = await chat();
		await say(replica, "$ seq 1 300");
		const window = await read(replica.id, { older: 3 });
		const output = window.entries.flatMap((entry) => entry.parts).find((part) => part.kind === "tool_output")!;
		assert.ok(output.truncated !== undefined && output.truncated.lines >= 300, JSON.stringify(output.truncated));
		assert.match(output.text, /300$/, "a command's end is kept");
		assert.ok(output.next !== undefined);
		const rest = await read(replica.id, output.next);
		const whole = rest.entries[0]!.parts[0]!;
		assert.equal(whole.kind, "tool_output");
		assert.match(whole.text, /^1\n2\n/);
		assert.equal(whole.truncated, undefined);
		const untruncated = await read(replica.id, { truncate: false });
		const full = untruncated.entries.flatMap((entry) => entry.parts).find((part) => part.kind === "tool_output")!;
		assert.equal(full.truncated, undefined);
		assert.equal(full.text.split("\n").filter((line) => line !== "").length, 300);
	});

	test("read: past a compaction, the entries before it are there, out of context", async () => {
		const replica = await chat();
		for (const word of ["alpha", "beta", "gamma", "delta"]) await say(replica, `${word} ${"filler ".repeat(60)}`);
		await client.request("conversation.compact", { conversationId: replica.id });
		await until(replica, () => replica.ordered().some((entry) => entry.kind === "pi.compaction") && idle(replica), 30_000);
		const all = await read(replica.id, { truncate: false, older: 50 });
		const first = all.entries.find((entry) => entry.parts.some((part) => part.text.startsWith("alpha")))!;
		assert.equal(first.inContext, false);
		assert.ok(all.entries.some((entry) => entry.parts.some((part) => part.summary === true)), "the summary, marked");
		// Read from another chat: no inContext.
		const other = await chat();
		const outside = await read(other.id, { link: history.link(replica.id) });
		assert.ok(outside.entries.every((entry) => entry.inContext === undefined));
	});

	test("read: a subagent by its link and its owner by alias; the card lists the subagents; a fork's origin", async () => {
		const leader = await chat("Leader");
		await say(leader, "& helper: look around");
		const card = await read(leader.id, {});
		const helper = card.chat.subagents?.find((agent) => agent.name === "helper");
		assert.ok(helper !== undefined, JSON.stringify(card.chat));
		const child = Number(helper.link.split("/").at(-1));
		const own = await read(child, { link: "this" });
		assert.equal(own.chat.owner?.link, history.link(leader.id));
		assert.equal(own.chat.owner?.title, "Leader");
		const owner = await read(child, { link: "owner" });
		assert.equal(owner.chat.link, history.link(leader.id));
		await assert.rejects(read(leader.id, { link: "owner" }), /no owner/);
		// A fork reads through into its origin's entries.
		const at = leader.ordered().find((entry) => entry.kind === "pi.user")!.id;
		const { dialog } = await client.request("conversation.fork", { conversationId: leader.id, at, requestId: `fork-${leader.id}` });
		const fork = await read(dialog.conversation.id, {});
		assert.equal(fork.chat.forkOf?.link, history.link(leader.id, at));
		assert.ok(fork.entries.some((entry) => entry.id === at));
	});

	test("read: a script calls history_read and gets objects", async () => {
		const replica = await chat("Scripted");
		await say(replica, "hello there");
		await say(replica, "!code const page = await tools.history_read({}); return [page.chat.title, page.entries.length, page.entries[0].parts[0].kind].join(' ');");
		const result = replica.ordered().findLast((entry) => entry.kind === "pi.tool-result")!;
		assert.match(JSON.stringify(result.model), /Scripted \d+ user/);
	});

	test("read: a link to another server, or to nothing, fails", async () => {
		const replica = await chat();
		await assert.rejects(read(replica.id, { link: "tau://ffffffff/1" }), /Not on this server/);
		await assert.rejects(read(replica.id, { link: history.link(999_999) }), /No chat/);
		await assert.rejects(read(replica.id, { link: "subagents" }), /search/);
		await assert.rejects(read(replica.id, { link: "nonsense" }), /Not a chat's link/);
	});
});
