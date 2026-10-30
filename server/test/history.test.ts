import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, describe, test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { ConversationId } from "@earendil-works/pi-durable";
import { ConversationReplica, TauClient } from "../src/client.ts";
import type { History, ReadArgs, ReadResult, SearchArgs, SearchResult } from "../src/history.ts";
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
	const search = (caller: number, args: SearchArgs): Promise<SearchResult> => history.search(caller as ConversationId, args, BACKGROUND_CONTEXT);
	/** Until the index has what was committed: it is written a tick after each commit. */
	const indexed = () => new Promise((resolve) => setTimeout(resolve, 50));

	before(async () => {
		host = await openHost({ devTokensPerSecond: 4_000, cwd: tmpdir() });
		server = await serve(host);
		client = await TauClient.connect(server.url);
		history = host.history;
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

	test("search: past the head, in subagents and in the owner, with inContext in the caller's own chat", async () => {
		const replica = await chat("Compacted");
		for (const word of ["xylophone", "beta", "gamma", "delta"]) await say(replica, `${word} ${"filler ".repeat(60)}`);
		await client.request("conversation.compact", { conversationId: replica.id });
		await until(replica, () => replica.ordered().some((entry) => entry.kind === "pi.compaction") && idle(replica), 30_000);
		await indexed();
		const found = await search(replica.id, { query: "xylophone", in: "this", kinds: ["user"] });
		assert.equal(found.total, 1);
		assert.equal(found.hits[0]!.inContext, false, "before the compaction's head");
		assert.match(found.hits[0]!.text!, /^«xylophone» filler/);
		assert.equal(found.hits[0]!.chat.title, "Compacted");
		assert.match(found.hits[0]!.time, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
		// From another chat: found, without inContext.
		const other = await chat();
		const elsewhere = await search(other.id, { query: "xylophone", kinds: ["user"] });
		assert.equal(elsewhere.hits[0]!.inContext, undefined);
		// Subagents and the owner.
		const leader = await chat("Boss");
		await say(leader, "& scout: find the quokka");
		const helper = (await read(leader.id, {})).chat.subagents![0]!;
		const child = Number(helper.link.split("/").at(-1));
		await until(leader, () => leader.ordered().some((entry) => JSON.stringify(entry.model ?? "").includes('status=\\"answered\\"')), 15_000);
		await indexed();
		const inSubagents = await search(leader.id, { query: "quokka", in: "subagents" });
		assert.ok(inSubagents.hits.length > 0 && inSubagents.hits.every((hit) => hit.chat.link === helper.link), JSON.stringify(inSubagents));
		const inOwner = await search(child, { query: "quokka", in: "owner", kinds: ["user"] });
		assert.ok(inOwner.hits.some((hit) => hit.chat.link === history.link(leader.id)), JSON.stringify(inOwner));
		assert.equal((await search(leader.id, { query: "xylophone", in: "subagents" })).total, 0);
	});

	test("search: exact by default, prefixes and typos with exact: false; smart case; phrases as written", async () => {
		const replica = await chat();
		await say(replica, "the compaction of Zebrafish logs");
		await say(replica, "node --conditions=source main.ts");
		await say(replica, "conditions, source and more");
		await indexed();
		const one = async (args: SearchArgs) => (await search(replica.id, { in: "this", kinds: ["user"], ...args })).total;
		assert.equal(await one({ query: "compacton" }), 0, "no typos when exact");
		assert.equal(await one({ query: "compacton", exact: false }), 1);
		assert.equal(await one({ query: "compac" }), 0, "no prefixes when exact");
		assert.equal(await one({ query: "compac", exact: false }), 1);
		assert.equal(await one({ query: "zebrafish" }), 1, "lower case: any case");
		assert.equal(await one({ query: "Zebrafish" }), 1);
		assert.equal(await one({ query: "ZebraFish" }), 0, "a capital: as written");
		assert.equal(await one({ query: '"--conditions=source"' }), 1, "punctuation as written");
		assert.equal(await one({ query: "conditions source" }), 2);
		assert.equal(await one({ query: "conditions source -main" }), 1);
		const hit = (await search(replica.id, { in: "this", kinds: ["user"], query: '"--conditions=source"' })).hits[0]!;
		assert.equal(hit.text, "node «--conditions=source» main.ts");
	});

	test("search: no query with kinds title lists chats by title, the most recently active first; mixed kinds too", async () => {
		const older = await chat("Titled older");
		await say(older, "first words");
		const newer = await chat("Titled newer");
		await say(newer, "second words");
		await indexed();
		const titles = await search(newer.id, { kinds: ["title"], limit: -1 });
		const links = titles.hits.map((hit) => hit.link);
		assert.ok(titles.hits.every((hit) => hit.kind === "title" && hit.link === hit.chat.link), JSON.stringify(titles));
		assert.ok(links.indexOf(history.link(newer.id)) < links.indexOf(history.link(older.id)) && links.indexOf(history.link(older.id)) >= 0, JSON.stringify(links));
		const titled = titles.hits.find((hit) => hit.link === history.link(newer.id))!;
		assert.equal(titled.text, "Titled newer");
		assert.equal(titled.chat.title, "Titled newer");
		// Activity moves a chat up.
		await say(older, "more words");
		await indexed();
		const again = await search(newer.id, { kinds: ["title"], limit: 2 });
		assert.equal(again.hits[0]!.link, history.link(older.id));
		assert.equal(again.total, titles.total);
		// In one chat: its title among its messages, at the chat's last activity, so first.
		const mixed = await search(older.id, { in: "this", kinds: ["user", "title"], limit: -1 });
		assert.deepEqual(mixed.hits.map((hit) => hit.kind), ["title", "user", "user"], JSON.stringify(mixed));
		assert.deepEqual(mixed.hits.slice(1).map((hit) => hit.text), ["more words", "first words"]);
		const oldest = await search(older.id, { in: "this", kinds: ["user", "title"], sort: "oldest" });
		assert.deepEqual(oldest.hits.map((hit) => hit.kind), ["user", "user", "title"]);
		// And everything, no kinds given: titles among the parts.
		const all = await search(older.id, { in: "this", limit: -1 });
		assert.ok(all.hits.some((hit) => hit.kind === "title") && all.hits.some((hit) => hit.kind === "assistant"), JSON.stringify(all));
	});

	test("search: next round-trips through every hit once; no query lists the newest first", async () => {
		const replica = await chat("Paged");
		for (let index = 1; index <= 7; index++) await say(replica, `pagination sample ${index}`);
		await indexed();
		const first = await search(replica.id, { query: "pagination", in: "this", kinds: ["user"], limit: 3 });
		assert.equal(first.total, 7);
		const links = first.hits.map((hit) => hit.link);
		let next = first.next;
		while (next !== undefined) {
			const page = await search(replica.id, next);
			links.push(...page.hits.map((hit) => hit.link));
			next = page.next;
		}
		assert.equal(links.length, 7);
		assert.equal(new Set(links).size, 7);
		const newest = await search(replica.id, { in: "this", kinds: ["user"], limit: 2 });
		assert.deepEqual(newest.hits.map((hit) => hit.text), ["pagination sample 7", "pagination sample 6"]);
		assert.equal(newest.total, 7);
		await assert.rejects(search(replica.id, { query: "x", cursor: "nonsense" }), /cursor/);
		await assert.rejects(search(replica.id, { query: "x", in: "tau://ffffffff/1" }), /Not on this server/);
	});

	test("search: sort by time, limit: -1 for every hit, text: false for links only, and complete: false past the scan cap", async () => {
		const replica = await chat("Sorted");
		for (let index = 1; index <= 5; index++) await say(replica, `ordering trial ${index}`);
		await indexed();
		const base = { query: "ordering", in: "this", kinds: ["user" as const] };
		assert.deepEqual((await search(replica.id, { ...base, sort: "newest", limit: 2 })).hits.map((hit) => hit.text), ["«ordering» trial 5", "«ordering» trial 4"]);
		assert.deepEqual((await search(replica.id, { ...base, sort: "oldest", limit: 2 })).hits.map((hit) => hit.text), ["«ordering» trial 1", "«ordering» trial 2"]);
		const all = await search(replica.id, { ...base, limit: -1 });
		assert.equal(all.hits.length, 5);
		assert.equal(all.next, undefined);
		assert.equal(all.complete, undefined);
		const links = await search(replica.id, { ...base, limit: -1, text: false });
		assert.ok(links.hits.every((hit) => hit.text === undefined && hit.link.startsWith("tau://")));
		// An index that stops at two matches says so.
		const real = history.index!;
		history.index = { hits: (query, options, context) => real.hits(query, { ...options, cap: 2 }, context), title: (id) => real.title(id) };
		try {
			const capped = await search(replica.id, { ...base, limit: -1 });
			assert.equal(capped.complete, false);
			assert.equal(capped.total, 2);
		} finally {
			history.index = real;
		}
	});

	test("search and read through the tools: several kinds pass through, one kind too", async () => {
		const replica = await chat("Kinds");
		await say(replica, "zebu grazing");
		await indexed();
		const results = async (command: string) => {
			await say(replica, command);
			const result = replica.ordered().findLast((entry) => entry.kind === "pi.tool-result")!;
			return JSON.parse((result.model as { content: { text: string }[] }[])[0]!.content[0]!.text) as { hits?: { kind: string }[]; entries?: { parts: { kind: string }[] }[] };
		};
		const both = await results("!tool history_search query=zebu in=this kinds=user,assistant");
		assert.deepEqual([...new Set(both.hits!.map((hit) => hit.kind))].sort(), ["assistant", "user"], JSON.stringify(both));
		const one = await results("!tool history_search query=zebu in=this kinds=assistant");
		assert.deepEqual([...new Set(one.hits!.map((hit) => hit.kind))], ["assistant"]);
		const read = await results("!tool history_read older=4 kinds=user,assistant");
		assert.ok(read.entries!.every((entry) => entry.parts.every((part) => part.kind === "user" || part.kind === "assistant")), JSON.stringify(read));
		assert.ok(read.entries!.some((entry) => entry.parts.some((part) => part.kind === "assistant")));
	});

	test("search: tool calls and output, linked to the call; the user's search leaves them out", async () => {
		const replica = await chat("Tools");
		await say(replica, "$ echo narwhal-77 && echo 'Error: narwhal exploded'");
		await indexed();
		const calls = await search(replica.id, { query: '"echo narwhal-77"', kinds: ["tool_call"] });
		assert.equal(calls.total, 1, JSON.stringify(calls));
		assert.match(calls.hits[0]!.text!, /^bash: «echo narwhal-77»/);
		const call = replica.ordered().find((entry) => entry.kind === "pi.assistant" && JSON.stringify(entry.model).includes("narwhal-77"))!;
		assert.equal(calls.hits[0]!.link, history.link(replica.id, call.id));
		const outputs = await search(replica.id, { query: "Error: narwhal", kinds: ["tool_output"] });
		assert.equal(outputs.total, 1);
		assert.equal(outputs.hits[0]!.link, history.link(replica.id, call.id), "the output's link is its call's");
		assert.match(outputs.hits[0]!.text!, /«Error:» «narwhal» exploded/);
		const shown = await read(replica.id, { link: outputs.hits[0]!.link, older: 0, newer: 0 });
		assert.deepEqual(shown.entries[0]!.parts.map((part) => part.kind), ["tool_call", "tool_output"]);
		// The user's search: what was said, not the logs.
		const user = await client.request("search", { query: "narwhal" });
		assert.ok(user.results.every((result: { hits: { kind: string }[] }) => result.hits.every((hit) => hit.kind !== "tool_call" && hit.kind !== "tool_output")), JSON.stringify(user));
	});
});

describe("history index from before tool calls", () => {
	const dir = mkdtempSync(join(tmpdir(), "tau-history-"));
	after(() => rmSync(dir, { recursive: true, force: true }));

	test("a start indexes the tool calls and output of the entries indexed before, once", async () => {
		const database = join(dir, "tau.db");
		let host = await openHost({ database, devTokensPerSecond: 4_000, cwd: tmpdir() });
		let server = await serve(host);
		let client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: "old", content: "$ echo okapi-42" });
		await until(replica, () => replica.submissions.get(submission.id)?.status === "done" && idle(replica));
		await new Promise((resolve) => setTimeout(resolve, 100));
		await client.close();
		await server.close();
		await host.close();
		// The index as version 4 left it: no tool parts, no tools cursor.
		const index = new DatabaseSync(join(dir, "tau.search.db"));
		index.exec("DELETE FROM fts WHERE rowid IN (SELECT rowid FROM part WHERE (rowid & 7) IN (4, 5))");
		index.exec("DELETE FROM part WHERE (rowid & 7) IN (4, 5)");
		index.exec("DROP INDEX part_time");
		index.exec("ALTER TABLE conv DROP COLUMN tools");
		index.exec("PRAGMA user_version = 4");
		index.close();
		for (let start = 0; start < 2; start++) {
			host = await openHost({ database, devTokensPerSecond: 4_000, cwd: tmpdir() });
			server = await serve(host);
			const found = await host.history.search(replica.id as ConversationId, { query: "okapi", kinds: ["tool_call", "tool_output"] }, BACKGROUND_CONTEXT);
			assert.deepEqual(found.hits.map((hit) => hit.kind).sort(), ["tool_call", "tool_output"], `start ${start}: ${JSON.stringify(found)}`);
			await server.close();
			await host.close();
		}
	});
});
