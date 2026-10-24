import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, type Entry, type Push, RequestError, TauClient } from "../src/client.ts";
import { Dialogs } from "../src/dialogs.ts";
import { type Host, openHost } from "../src/host.ts";
import { clientEntry, clientOp } from "../src/outgoing.ts";
import { WebSocket } from "ws";
import { type Server, serve } from "../src/server.ts";

const MAIN = join(import.meta.dirname, "..", "src", "main.ts");

async function start(options: { database?: string; tps?: number } = {}): Promise<{ host: Host; server: Server }> {
	const host = await openHost({
		...(options.database === undefined ? {} : { database: options.database }),
		devTokensPerSecond: options.tps ?? 2_000,
		cwd: tmpdir(),
	});
	return { host, server: await serve(host) };
}

function until(replica: ConversationReplica, predicate: () => boolean, timeoutMs = 10_000): Promise<void> {
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
const kinds = (replica: ConversationReplica) => replica.ordered().map((entry) => entry.kind);

async function chat(client: TauClient, replica: ConversationReplica, content: string, requestId: string): Promise<void> {
	const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId, content });
	await until(replica, () => replica.submissions.get(submission.id)?.status === "done" && idle(replica));
}

function assistantText(entry: Entry | undefined): string {
	const message = (entry as { model?: { content: { type: string; text?: string }[] }[] } | undefined)?.model?.[0];
	return message?.content.find((part) => part.type === "text")?.text ?? "";
}

describe("tau server", () => {
	let host: Host;
	let server: Server;
	// Slow enough that answers stream over several progress commits, and runs can be caught mid-way.
	let slow: { host: Host; server: Server };
	before(async () => {
		({ host, server } = await start());
		slow = await start({ tps: 100 });
	});
	after(async () => {
		for (const each of [{ host, server }, slow]) {
			await each.server.close();
			await each.host.close();
		}
	});

	test("with a token, refuses a client without it or with another", async () => {
		const locked = await serve(host, { token: "a-token-long-enough-to-pass" });
		try {
			await assert.rejects(TauClient.connect(locked.url), /401/);
			await assert.rejects(TauClient.connect(locked.url, "a-token-long-enough-to-fail"), /401/);
			const client = await TauClient.connect(locked.url, "a-token-long-enough-to-pass");
			await client.close();
		} finally {
			await locked.close();
		}
	});

	test("the command line refuses to listen beyond loopback without a token", async () => {
		const child = spawn(process.execPath, ["--no-warnings", MAIN, "--memory", "--host", "0.0.0.0", "--port", "0"], { env: { ...process.env, TAU_TOKEN: "" } });
		let output = "";
		child.stderr.on("data", (chunk) => (output += chunk));
		const code = await new Promise((resolve) => child.on("exit", resolve));
		assert.equal(code, 1);
		assert.match(output, /not loopback/);
	});

	test("closes a socket nothing comes in on, and keeps one that answers its pings", async () => {
		const quick = await serve(host, { idleTimeoutMs: 300 });
		try {
			// A client gone quiet: it answers no ping (a phone that lost its network, or a suspended app).
			const silent = new WebSocket(quick.url, { autoPong: false });
			await new Promise((resolve) => silent.once("open", resolve));
			const closed = new Promise((resolve) => silent.once("close", resolve));
			const answering = await TauClient.connect(quick.url);
			let answeringClosed = false;
			const started = Date.now();
			await closed;
			assert.ok(Date.now() - started < 1_500, "closed within the timeout");
			await new Promise((resolve) => setTimeout(resolve, 700));
			await answering.request("client.presence", { active: false }).catch(() => {
				answeringClosed = true;
			});
			assert.equal(answeringClosed, false, "a client that answers pings stays");
			await answering.close();
		} finally {
			await quick.close();
		}
	});

	test("clients get no provider replay data, and pi.system entries without the prompt", () => {
		const entry = {
			id: 7,
			kind: "pi.assistant",
			conversationId: 1,
			model: [{ role: "assistant", content: [{ type: "thinking", thinking: "hm", thinkingSignature: "x".repeat(100) }, { type: "text", text: "hi", textSignature: "s" }, { type: "toolCall", id: "c", name: "bash", arguments: {}, thoughtSignature: "t" }] }],
		};
		const shown = clientEntry(entry as never) as unknown as typeof entry;
		assert.deepEqual(shown.model[0]!.content, [{ type: "thinking", thinking: "hm" }, { type: "text", text: "hi" }, { type: "toolCall", id: "c", name: "bash", arguments: {} }]);
		assert.equal(entry.model[0]!.content[0]!.thinkingSignature?.length, 100, "the stored entry is left as it is");
		const plain = { id: 8, kind: "pi.user", conversationId: 1, model: [{ role: "user", content: "hello" }] };
		assert.equal(clientEntry(plain as never), plain, "nothing to leave out: the same object");
		assert.deepEqual(clientEntry({ id: 9, kind: "pi.system", conversationId: 1, model: [{ role: "system", toolsAdded: [] }] } as never), { id: 9, kind: "pi.system", conversationId: 1 });
		// Streaming: an op that writes a signature goes; one that carries one in its value loses it.
		assert.equal(clientOp(["s", ["pi.live", "generation", "message", "content", 0, "thinkingSignature"], "sig"]), undefined);
		assert.equal(clientOp(["a", ["pi.live", "generation", "message", "content", 0, "thinkingSignature"], "more"]), undefined);
		assert.deepEqual(clientOp(["s", ["pi.live", "generation", "message"], { content: [{ type: "thinking", thinking: "a", thinkingSignature: "sig" }] }] as never), ["s", ["pi.live", "generation", "message"], { content: [{ type: "thinking", thinking: "a" }] }]);
		assert.deepEqual(clientOp(["a", ["pi.live", "generation", "message", "content", 0, "text"], "x"]), ["a", ["pi.live", "generation", "message", "content", 0, "text"], "x"]);
	});

	test("requires hello with the right protocol", async () => {
		const client = await TauClient.connect(server.url);
		await assert.rejects(client.request("hello", { protocol: 99 }), (error: RequestError) => error.code === "bad_request");
		await client.close();
	});

	test("streams an answer and ends with a consistent replica", async () => {
		const client = await TauClient.connect(slow.server.url);
		const { dialog } = await client.request("conversation.create", { title: "stream" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		let partials = 0;
		replica.onChange(() => {
			if ((replica.docs["pi.live"] as { generation?: { message?: unknown } })?.generation?.message) partials++;
		});
		await chat(client, replica, "hello there", "a");
		assert.deepEqual(kinds(replica), ["pi.user", "pi.system", "pi.assistant"]);
		assert.match(assistantText(replica.ordered().at(-1)), /You said: hello there/);
		assert.ok(partials > 0, "saw streamed partials");

		// The ops applied client-side reproduce the server's docs exactly.
		const fresh = await TauClient.connect(slow.server.url);
		const snapshot = await fresh.request("conversation.subscribe", { conversationId: replica.id });
		assert.deepEqual(replica.docs, snapshot.docs);
		await fresh.close();
		await client.close();
	});

	test("a requestId makes submit idempotent", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const id = dialog.conversation.id;
		const first = await client.request("conversation.submit", { conversationId: id, requestId: "same", content: "one" });
		const second = await client.request("conversation.submit", { conversationId: id, requestId: "same", content: "one" });
		assert.equal(second.submission.id, first.submission.id);
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		await until(replica, () => idle(replica) && replica.entries.size >= 3);
		assert.equal(kinds(replica).filter((kind) => kind === "pi.user").length, 1);
		await client.close();
	});

	test("runs tools", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await chat(client, replica, "$ echo tool-ran", "t");
		assert.deepEqual(kinds(replica), ["pi.user", "pi.system", "pi.assistant", "pi.tool-result", "pi.assistant"]);
		assert.match(assistantText(replica.ordered().at(-1)), /tool-ran/);
		await client.close();
	});

	test("reconnect fetches only newer entries, and a big gap becomes a hole that history fills", async () => {
		const writer = await TauClient.connect(server.url);
		const { dialog } = await writer.request("conversation.create", {});
		const id = dialog.conversation.id;
		const live = new ConversationReplica(id);
		await live.sync(writer);
		await chat(writer, live, "first", "1");

		const phone = new ConversationReplica(id);
		const connection = await TauClient.connect(server.url);
		await phone.sync(connection);
		assert.equal(phone.entries.size, 3);
		phone.detach();
		await connection.close();

		// Offline: ten more exchanges.
		for (let i = 0; i < 10; i++) await chat(writer, live, `message ${i}`, `m${i}`);

		const back = await TauClient.connect(server.url);
		await phone.sync(back, { limit: 5 });
		assert.equal(phone.holes.length, 1, "more than limit missing: a hole");
		const newest = live.ordered().slice(-5).map((entry) => entry.id);
		for (const entryId of newest) assert.ok(phone.entries.has(entryId));
		while (phone.holes.length > 0) await phone.fillHole(back, 4);
		assert.deepEqual(
			phone.ordered().map((entry) => entry.id),
			live.ordered().map((entry) => entry.id),
		);
		await back.close();
		await writer.close();
	});

	test("first open loads the tail; scrolling up pages the rest", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const live = new ConversationReplica(dialog.conversation.id);
		await live.sync(client);
		for (let i = 0; i < 6; i++) await chat(client, live, `n${i}`, `n${i}`);

		const phone = new ConversationReplica(dialog.conversation.id);
		await phone.sync(client, { limit: 4 });
		assert.equal(phone.entries.size, 4);
		assert.equal(phone.hasOlder, true);
		while (phone.hasOlder) await phone.loadOlder(client, 3);
		assert.deepEqual(
			phone.ordered().map((entry) => entry.id),
			live.ordered().map((entry) => entry.id),
		);
		await client.close();
	});

	test("history without before brings a cached tail up to date, and says when there is a gap", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const id = dialog.conversation.id;
		const live = new ConversationReplica(id);
		await live.sync(client);
		await chat(client, live, "first", "1");
		const ids = () => live.ordered().map((entry) => entry.id);
		const cached = ids().at(-1)!;
		for (let i = 0; i < 3; i++) await chat(client, live, `more ${i}`, `more${i}`);

		// The newest, never subscribing: what the app preloads for a chat it has not opened.
		const newest = await client.request("conversation.history", { conversationId: id, limit: 4 });
		assert.deepEqual(newest.entries.map((entry: { id: number }) => entry.id), ids().slice(-4));
		assert.equal(newest.hasOlder, true);
		const after = await client.request("conversation.history", { conversationId: id, after: cached, limit: 100 });
		assert.deepEqual(after.entries.map((entry: { id: number }) => entry.id), ids().filter((entryId) => entryId > cached));
		assert.equal(after.hasOlder, false, "everything since the cache: no gap");
		const gap = await client.request("conversation.history", { conversationId: id, after: cached, limit: 2 });
		assert.equal(gap.hasOlder, true, "more than limit since the cache: a gap");
		await client.close();
	});

	test("dialogs: listed, pushed on create and on run start and end", async () => {
		const client = await TauClient.connect(server.url);
		const pushes: { busy: boolean; id: number; last?: { kind: string } }[] = [];
		client.on((push: Push) => {
			if (push.event !== "dialog") return;
			const dialog = push.dialog as { busy: boolean; conversation: { id: number }; last?: { kind: string } };
			pushes.push({ busy: dialog.busy, id: dialog.conversation.id, last: dialog.last });
		});
		await client.request("dialogs.subscribe");
		const { dialog } = await client.request("conversation.create", {});
		const id = dialog.conversation.id;
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		await chat(client, replica, "list me", "d");
		await new Promise((resolve) => setTimeout(resolve, 100));
		const mine = pushes.filter((push) => push.id === id);
		assert.ok(mine.some((push) => push.busy));
		assert.equal(mine.at(-1)?.busy, false);
		assert.equal(mine.at(-1)?.last?.kind, "pi.assistant");
		const { dialogs } = await client.request("dialogs.subscribe");
		assert.equal(dialogs[0].conversation.id, id, "most recent first");
		assert.equal(dialogs[0].title, "list me");
		await client.close();
	});

	test("dialogs kept up to date read as they would from scratch, and a version gives only what changed since", async () => {
		const client = await TauClient.connect(server.url);
		// One that will not change.
		await client.request("conversation.create", { title: "Unchanged" });
		const first = await client.request("dialogs.subscribe");
		assert.equal(first.full, true);
		const { dialog } = await client.request("conversation.create", {});
		const id = dialog.conversation.id;
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		await chat(client, replica, "one", "k1");
		await chat(client, replica, "$ echo two", "k2");
		const answers = replica.ordered().filter((entry) => entry.kind === "pi.assistant");
		await client.request("conversation.read", { conversationId: id, at: answers[0]!.id });
		await chat(client, replica, "three", "k3");
		await client.request("conversation.rename", { conversationId: id, title: "Kept" });

		const changed = await client.request("dialogs.subscribe", { since: first.version });
		assert.equal(changed.full, false);
		const kept = changed.dialogs.find((each: { conversation: { id: number } }) => each.conversation.id === id);
		assert.ok(kept, "the changed chat is in the changes");
		assert.ok(changed.dialogs.length < (await client.request("dialogs.subscribe")).dialogs.length, "only what changed");
		// From scratch: a new chat list, as after a restart.
		const fresh = new Dialogs(host);
		await fresh.ready();
		const scratch = fresh.list().dialogs.find((each) => each.conversation.id === id);
		fresh.close();
		assert.deepEqual(kept, scratch);
		assert.equal(kept!.title, "Kept");
		assert.ok(kept!.unreadCount >= 2, "the answers after the read mark");

		const none = await client.request("dialogs.subscribe", { since: changed.version });
		assert.deepEqual(none.dialogs, [], "nothing since");
		assert.equal((await client.request("dialogs.subscribe", { since: "another:3" })).full, true, "a version from another process: all of them");
		await client.close();
		// Another process (a restart): the old version gives the whole list.
		const restarted = await serve(host);
		try {
			const again = await TauClient.connect(restarted.url);
			assert.equal((await again.request("dialogs.subscribe", { since: changed.version })).full, true);
			await again.close();
		} finally {
			await restarted.close();
		}
	});

	test("keeps an idle chat's big prompt warm in idle mode, and stops when the setting says so", async () => {
		// Twelve thousand tokens: between runs a refresh pays (a 15% chance of a miss at four times Opus prices) where a
		// small prompt's does not.
		const warm = await openHost({ devTokensPerSecond: 20_000, devCacheTtl: 11, cwd: tmpdir() });
		const warmServer = await serve(warm);
		try {
			const client = await TauClient.connect(warmServer.url);
			const caches: ({ warming?: true; warms?: number } | undefined)[] = [];
			client.on((push: Push) => {
				if (push.event === "dialog") caches.push((push.dialog as { cache?: { warming?: true; warms?: number } }).cache);
			});
			await client.request("dialogs.subscribe");
			const { dialog } = await client.request("conversation.create", {});
			const replica = new ConversationReplica(dialog.conversation.id);
			await replica.sync(client);
			await chat(client, replica, `remember this: ${"lorem ipsum dolor sit amet ".repeat(1_800)}`, "i1");
			await new Promise((resolve) => setTimeout(resolve, 3_500));
			const idle = caches.at(-1);
			assert.equal(idle?.warming, true, "kept warm after the run");
			assert.ok((idle?.warms ?? 0) >= 2, `refreshed ${idle?.warms} times while idle`);
			const { cacheWarming } = await client.request("settings.configure", { cacheWarming: "streaming" });
			assert.equal(cacheWarming, "streaming");
			await new Promise((resolve) => setTimeout(resolve, 100));
			assert.equal(caches.at(-1)?.warming, undefined, "only while working now");
			await client.close();
		} finally {
			await warmServer.close();
			await warm.close();
		}
	});

	test("keeps a working conversation's prompt cache warm, and lets an idle one's go", async () => {
		// An 11 s lifetime refreshes every second; a 13 s command outlives it, so only refreshes keep the cache for the
		// answer after it.
		const warm = await openHost({ devTokensPerSecond: 2_000, devCacheTtl: 11, cwd: tmpdir() });
		const warmServer = await serve(warm);
		try {
			const client = await TauClient.connect(warmServer.url);
			const pushes: { cache?: { ttl: number; at: number; warming?: true; warms?: number; cost?: number; saved?: number } }[] = [];
			client.on((push: Push) => {
				if (push.event === "dialog") pushes.push(push.dialog as (typeof pushes)[number]);
			});
			await client.request("dialogs.subscribe");
			const { dialog } = await client.request("conversation.create", {});
			const replica = new ConversationReplica(dialog.conversation.id);
			await replica.sync(client);
			await chat(client, replica, "hello", "w1");
			await new Promise((resolve) => setTimeout(resolve, 100));
			const first = pushes.at(-1)?.cache;
			assert.equal(first?.ttl, 11_000);
			assert.equal(first?.warming, undefined, "an idle conversation with a small prompt is not kept warm: it would not pay");
			assert.equal(first?.warms, undefined);
			const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: "w2", content: "$ sleep 13" });
			await until(replica, () => replica.submissions.get(submission.id)?.status === "done" && idle(replica), 30_000);
			await new Promise((resolve) => setTimeout(resolve, 200));
			assert.ok(pushes.some((push) => push.cache?.warming === true), "warming while the command runs");
			const last = pushes.at(-1)?.cache;
			assert.equal(last?.warming, undefined, "no longer once the run ends");
			assert.ok((last?.warms ?? 0) >= 8, `refreshed ${last?.warms} times`);
			assert.ok((last?.cost ?? 0) > 0);
			assert.ok((last?.saved ?? 0) > 0, "the answer after the command read what refreshes kept");
			// The Usage screen counts the refreshes as a model of their own, and not as answers.
			const report = (await client.request("usage.report", { days: 1 })) as { models: { model: string; replies: number; cost: number }[]; total: { replies: number } };
			const refreshes = report.models.find((each) => each.model === "tau/cache-warming");
			assert.equal(refreshes?.replies, last?.warms);
			assert.ok(Math.abs((refreshes?.cost ?? 0) - (last?.cost ?? 0)) < 1e-9);
			assert.equal(report.total.replies, 3, "hello, the command call, and the answer after it");
			await client.close();
		} finally {
			await warmServer.close();
			await warm.close();
		}
	});

	test("shows a prompt cache only while it is the one of the conversation's model, and not after a reset", async () => {
		const warm = await openHost({ devTokensPerSecond: 2_000, devCacheTtl: 30, cwd: tmpdir() });
		const warmServer = await serve(warm);
		try {
			const client = await TauClient.connect(warmServer.url);
			type Cache = { ttl?: number; at?: number; warming?: true; warms?: number };
			let latest: { cache?: Cache } | undefined;
			const { dialog } = await client.request("conversation.create", {});
			const id = dialog.conversation.id;
			// Read through a function: the assertions would narrow the variable.
			const current = (): Cache | undefined => latest?.cache;
			client.on((push: Push) => {
				if (push.event === "dialog" && (push.dialog as { conversation: { id: number } }).conversation.id === id) latest = push.dialog as typeof latest;
			});
			await client.request("dialogs.subscribe");
			const replica = new ConversationReplica(id);
			await replica.sync(client);
			const settle = () => new Promise((resolve) => setTimeout(resolve, 150));
			const configure = async (modelId: string) => {
				await client.request("conversation.configure", { conversationId: id, agent: { model: { provider: "dev", modelId } } });
				await settle();
			};
			await chat(client, replica, "hello", "c1");
			await settle();
			const first = current();
			assert.equal(first?.ttl, 30_000);
			assert.ok(first?.at !== undefined);
			// Another model has another cache: the next request would not read this one.
			await configure("echo-uncached");
			assert.equal(current(), undefined, "not the new model's cache");
			await chat(client, replica, "and now?", "c2");
			await settle();
			assert.equal(current(), undefined, "a model without a declared lifetime shows none, and leaves no stale one");
			// Back to the first model within its lifetime: its cache is the conversation's again.
			await configure("echo");
			assert.deepEqual(current(), { ttl: 30_000, at: first!.at });
			await chat(client, replica, "once more", "c3");
			await settle();
			assert.ok((current()?.at ?? 0) > first!.at!, "the new request read or wrote it");
			// A reset gives the next request another prompt.
			await client.request("conversation.reset", { conversationId: id });
			await until(replica, () => replica.ordered().some((entry) => entry.kind === "pi.reset") && idle(replica));
			await settle();
			assert.equal(current(), undefined, "nothing the next request reads");
			await client.close();
		} finally {
			await warmServer.close();
			await warm.close();
		}
	});

	test("images go by reference, and come with media.get", async () => {
		// A 3 by 2 PNG, uploaded and sent as a photo (docs/files.md).
		const png = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEklEQVR4nGP4z8DwHwYZYBwAeKgL9dO6vN0AAAAASUVORK5CYII=";
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const upload = (await (await fetch(`${server.url.replace(/^ws/, "http")}/files?name=dot.png`, { method: "POST", body: Buffer.from(png, "base64") })).json()) as { id: string };
		const { submission } = await client.request("conversation.submit", {
			conversationId: replica.id,
			requestId: "m1",
			content: "look",
			attachments: [{ id: upload.id, as: "image" }],
		});
		await until(replica, () => replica.submissions.get(submission.id)?.status === "done" && idle(replica));
		const user = replica.ordered().find((entry) => entry.kind === "pi.user") as unknown as { id: number; model: { content: { type: string; data?: string; media?: { entryId: number; index: number; bytes: number; width: number; height: number } }[] }[] };
		const image = user.model[0]!.content.find((block) => block.type === "image")!;
		assert.equal(image.data, undefined, "no data in the entry");
		assert.deepEqual(image.media, { entryId: user.id, index: 0, bytes: Math.floor((png.length * 3) / 4), width: 3, height: 2 });
		const fetched = await client.request("media.get", { conversationId: replica.id, entryId: user.id, index: 0 });
		assert.deepEqual(fetched, { mimeType: "image/png", data: png });
		await assert.rejects(client.request("media.get", { conversationId: replica.id, entryId: user.id, index: 1 }), (error: RequestError) => error.code === "not_found");
		await client.close();
	});

	test("read marks, Mark as Unread, archive, and the default model", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const id = dialog.conversation.id;
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		await chat(client, replica, "one", "r1");
		await chat(client, replica, "two", "r2");
		const find = async () => {
			const { dialogs } = await client.request("dialogs.subscribe");
			return dialogs.find((each: { conversation: { id: number } }) => each.conversation.id === id);
		};
		assert.equal((await find()).unreadCount, 2);
		const first = replica.ordered().find((entry) => entry.kind === "pi.assistant");
		await client.request("conversation.read", { conversationId: id, at: first?.id });
		assert.equal((await find()).unreadCount, 1);
		await client.request("conversation.mark", { conversationId: id, unread: false });
		assert.equal((await find()).unreadCount, 0);
		await client.request("conversation.mark", { conversationId: id, unread: true, archived: true });
		let found = await find();
		assert.equal(found.markedUnread, true);
		assert.equal(found.archived, true);
		await client.request("conversation.read", { conversationId: id, at: replica.ordered().at(-1)?.id });
		found = await find();
		assert.equal(found.markedUnread, undefined);
		assert.equal(found.archived, true, "reading keeps it archived");

		const { dialog: fork } = await client.request("conversation.fork", { conversationId: id, at: replica.ordered().at(-1)?.id });
		assert.equal(fork.unreadCount, 0, "a fork starts read");
		assert.equal(fork.archived, undefined, "a fork starts in the main list");

		const model = { provider: "dev", modelId: "echo-2" };
		assert.deepEqual((await client.request("settings.configure", { defaultModel: model })).defaultModel, model);
		assert.deepEqual((await client.request("hello", { protocol: 1 })).defaultModel, model);
		await client.request("settings.configure", { defaultModel: { provider: "dev", modelId: "echo" } });
		await client.close();
	});

	test("a chat runs where the server starts chats; the client has no say", async () => {
		const client = await TauClient.connect(server.url);
		const hello = await client.request("hello", { protocol: 1 });
		assert.equal(hello.defaultCwd, undefined);
		// A directory in the agent patch is not the client's to set.
		const { dialog } = await client.request("conversation.create", { agent: { cwd: homedir() } });
		assert.equal(dialog.agent.cwd, undefined);
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await chat(client, replica, "$ pwd", "pwd");
		assert.equal(realpathSync(assistantText(replica.ordered().at(-1)).match(/```\n(.*)\n```/)![1]!), realpathSync(tmpdir()));
		await client.close();
	});

	test("whenBusy reject, steer, and abort", async () => {
		const client = await TauClient.connect(slow.server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "long", content: "a long one" });
		await until(replica, () => !idle(replica));
		await assert.rejects(
			client.request("conversation.submit", { conversationId: replica.id, requestId: "r", content: "x", whenBusy: "reject" }),
			(error: RequestError) => error.code === "busy",
		);
		await client.request("conversation.abort", { conversationId: replica.id });
		await until(replica, () => idle(replica));
		const settled = [...replica.submissions.values()].find((record) => record.requestId === "long");
		assert.equal(settled?.status, "unanswered");
		await client.close();
	});

	test("submits keep their order, even fired without waiting", async () => {
		const client = await TauClient.connect(slow.server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const texts = ["one", "two", "three", "four", "five"];
		await Promise.all(
			texts.map((content, index) =>
				client.request("conversation.submit", { conversationId: replica.id, requestId: `o${index}`, content, whenBusy: "followUp" }),
			),
		);
		await until(replica, () => idle(replica) && replica.ordered().filter((entry) => entry.kind === "pi.user").length === 5, 30_000);
		const users = replica.ordered().filter((entry) => entry.kind === "pi.user");
		const sent = users.map((entry) => (entry as unknown as { model: { content: string }[] }).model[0]!.content);
		assert.deepEqual(sent, texts);
		await client.close();
	});

	test("withdraw: a queued message leaves, a placed one stays, an unknown one can never arrive", async () => {
		const client = await TauClient.connect(slow.server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const id = replica.id;
		await client.request("conversation.submit", { conversationId: id, requestId: "first", content: "a long one" });
		await until(replica, () => !idle(replica));
		const { submission: queued } = await client.request("conversation.submit", { conversationId: id, requestId: "later", content: "later", whenBusy: "followUp" });
		assert.equal(queued.status, "queued");
		const withdrawn = await client.request("submission.withdraw", { conversationId: id, requestId: "later" });
		assert.equal(withdrawn.result, "aborted");
		assert.equal(withdrawn.submission.status, "unanswered");
		// Again: already settled, and still not in the transcript.
		assert.equal((await client.request("submission.withdraw", { conversationId: id, requestId: "later" })).result, "settled");
		// The running one is in the transcript.
		assert.equal((await client.request("submission.withdraw", { conversationId: id, requestId: "first" })).result, "already_placed");
		// Withdrawn before its submit arrived: the submit is refused.
		assert.equal((await client.request("submission.withdraw", { conversationId: id, requestId: "ghost" })).result, "withdrawn");
		await assert.rejects(
			client.request("conversation.submit", { conversationId: id, requestId: "ghost", content: "boo" }),
			(error: RequestError) => error.code === "withdrawn",
		);
		// A withdraw queued behind its submit on the same socket sees the submission.
		const [submitted, raced] = await Promise.all([
			client.request("conversation.submit", { conversationId: id, requestId: "race", content: "race", whenBusy: "followUp" }),
			client.request("submission.withdraw", { conversationId: id, requestId: "race" }),
		]);
		assert.equal(submitted.submission.status, "queued");
		assert.equal(raced.result, "aborted");
		await client.request("conversation.abort", { conversationId: id });
		await until(replica, () => idle(replica));
		const users = replica.ordered().filter((entry) => entry.kind === "pi.user").map((entry) => (entry as unknown as { model: { content: string }[] }).model[0]!.content);
		assert.deepEqual(users, ["a long one"]);
		await client.close();
	});

	test("content the model cannot take is refused before admission", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const id = dialog.conversation.id;
		await assert.rejects(
			client.request("conversation.submit", { conversationId: id, requestId: "big", content: "x".repeat(1_000_001) }),
			(error: RequestError) => error.code === "too_large",
		);
		// Photos are attachments, not content.
		await assert.rejects(
			client.request("conversation.submit", { conversationId: id, requestId: "img", content: [{ type: "image", data: "AAAA", mimeType: "image/png" }] }),
			(error: RequestError) => error.code === "bad_request",
		);
		await assert.rejects(
			client.request("conversation.submit", { conversationId: 999_999, requestId: "nowhere", content: "hi" }),
			(error: RequestError) => error.code === "not_found",
		);
		// Nothing was admitted: the same request IDs still work.
		const { submission } = await client.request("conversation.submit", { conversationId: id, requestId: "big", content: "small" });
		assert.equal(submission.requestId, "big");
		await client.close();
	});

	test("a create with a request ID happens once", async () => {
		const client = await TauClient.connect(server.url);
		const [a, b] = await Promise.all([
			client.request("conversation.create", { requestId: "make-once", title: "Once" }),
			client.request("conversation.create", { requestId: "make-once", title: "Once" }),
		]);
		assert.equal(a.dialog.conversation.id, b.dialog.conversation.id);
		const again = await client.request("conversation.create", { requestId: "make-once" });
		assert.equal(again.dialog.conversation.id, a.dialog.conversation.id);
		await client.close();
	});

	test("the default thinking level is fitted to the model a conversation gets", async () => {
		const client = await TauClient.connect(server.url);
		const settings = await client.request("settings.configure", { defaultThinkingLevel: "xhigh" });
		assert.equal(settings.defaultThinkingLevel, "xhigh");
		const { models } = await client.request("models.list", {});
		const echo = models.find((model: { provider: string }) => model.provider === "dev");
		assert.deepEqual(echo.thinkingLevels, ["off", "minimal", "low", "medium", "high"]);
		const { dialog } = await client.request("conversation.create", { title: "Thinks" });
		const id = dialog.conversation.id;
		const view = await client.request("conversation.subscribe", { conversationId: id });
		// The echo model has no xhigh: the nearest level it has.
		assert.equal(view.docs["pi.agent"]?.thinkingLevel, "high");
		await client.request("conversation.configure", { conversationId: id, agent: { thinkingLevel: "max" } });
		const after = await client.request("conversation.subscribe", { conversationId: id });
		assert.equal(after.docs["pi.agent"]?.thinkingLevel, "high");
		await client.request("settings.configure", { defaultThinkingLevel: "off" });
		await client.close();
	});

	test("a background subagent never blocks its conversation, and its answer comes back", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Parent" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "spawn", content: "& reader: $ sleep 1 && echo found it" });
		// The parent's run ends with the tool's reply while the subagent still works.
		await until(replica, () => idle(replica) && kinds(replica).includes("pi.tool-result"));
		const reports = () => replica.ordered().filter((entry) => entry.kind === "pi.user" && JSON.stringify(entry.model).includes('<subagent name=\\"reader\\"'));
		assert.equal(reports().length, 0);
		// The answer arrives later as a message of the parent, in the format the app shows as the subagent's card.
		await until(replica, () => reports().length === 1 && idle(replica));
		assert.match(JSON.stringify(reports()[0]!.model), /found it/);
		await client.close();
	});

	test("a subagent can start from a copy of its conversation, at another effort", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Forking parent" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "context", content: "the secret is 42" });
		await until(replica, () => idle(replica) && kinds(replica).includes("pi.assistant"));
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "fork-spawn", content: "& helper fork thinking=xhigh: what is the secret" });
		await until(replica, () => idle(replica) && kinds(replica).includes("pi.tool-result"));
		const result = replica.ordered().findLast((entry) => entry.kind === "pi.tool-result")!;
		const details = (result.model as { details?: { conversationId: number; fork?: boolean; thinking?: string } }[])[0]!.details!;
		assert.equal(details.fork, true);
		// The echo model has no xhigh: the nearest level it has.
		assert.equal(details.thinking, "high");
		const child = new ConversationReplica(details.conversationId);
		await child.sync(client);
		await until(child, () => idle(child) && JSON.stringify(child.ordered()).includes("what is the secret"));
		// The copy holds the conversation up to the request, and not the call itself.
		const texts = JSON.stringify(child.ordered().map((entry) => entry.model));
		assert.match(texts, /the secret is 42/);
		assert.doesNotMatch(texts, /"toolCall"/);
		const view = await client.request("conversation.subscribe", { conversationId: details.conversationId });
		assert.equal(view.docs["pi.agent"]?.thinkingLevel, "high");
		await client.close();
	});

	test("search finds what was said, as it is written, with the word being typed", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Search me" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "s-1", content: "the quokka sleeps under CommandPalette 压缩上下文" });
		await until(replica, () => idle(replica) && replica.ordered().some((entry) => entry.kind === "pi.assistant"));
		await new Promise((resolve) => setTimeout(resolve, 50));
		const found = await client.request("search", { query: "quokka" });
		const result = found.results.find((each: { conversationId: number }) => each.conversationId === replica.id);
		assert.ok(result, "the conversation is found");
		assert.match(result.hits[0].text, /quokka/i);
		const [start, end] = result.hits[0].ranges[0];
		assert.equal(result.hits[0].text.slice(start, end).toLowerCase(), "quokka");
		// The word being typed, an identifier's part, a CJK word, a typo, and the title.
		for (const [query, typing] of [["quok", true], ["palette", false], ["压缩", false], ["quokke", false], ["search me", false]] as const) {
			const response = await client.request("search", { query, typing });
			assert.ok(response.results.some((each: { conversationId: number }) => each.conversationId === replica.id), query);
		}
		// In the chat: its matching entries, newest first.
		const inChat = await client.request("search", { query: "quokka", conversationId: replica.id });
		assert.ok(inChat.hits.length >= 1);

		// Hidden, on every device: flagged in the dialogs, out of search; shown again, back in it.
		const has = async () => (await client.request("search", { query: "quokka" })).results.some((each: { conversationId: number }) => each.conversationId === replica.id);
		const dialogOf = async () => (await client.request("dialogs.subscribe")).dialogs.find((each: { conversation: { id: number } }) => each.conversation.id === replica.id);
		await client.request("conversation.mark", { conversationId: replica.id, hidden: true });
		await new Promise((resolve) => setTimeout(resolve, 50));
		assert.equal((await dialogOf()).hidden, true);
		assert.equal(await has(), false, "a hidden conversation is not found");
		await client.request("conversation.mark", { conversationId: replica.id, hidden: false });
		await new Promise((resolve) => setTimeout(resolve, 50));
		assert.equal((await dialogOf()).hidden, undefined);
		assert.equal(await has(), true, "shown again, it is found");
		await client.close();
	});

	test("usage reports each answer once, by day, model and conversation", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Spend" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "u-1", content: "count me" });
		await until(replica, () => idle(replica) && replica.ordered().some((entry) => entry.kind === "pi.assistant"));
		await new Promise((resolve) => setTimeout(resolve, 50));
		const report = await client.request("usage.report", { days: 7, tzOffset: 120 });
		assert.equal(report.days.length, 7);
		const mine = report.conversations.find((each: { conversationId: number }) => each.conversationId === replica.id);
		assert.equal(mine.replies, 1);
		assert.ok(report.models.some((each: { model: string }) => each.model === "dev/echo"));
		assert.ok(Object.keys(report.days.at(-1).models).includes("dev/echo"));
		await client.close();
	});

	test("an overloaded provider is asked again until it answers", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Overloaded" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "o-1", content: "!overloaded 1 hi" });
		await until(replica, () => idle(replica) && replica.ordered().some((entry) => entry.kind === "pi.assistant" && (entry.model as any)?.[0]?.stopReason === "stop"), 10_000);
		const errors = replica.ordered().filter((entry) => (entry.model as any)?.[0]?.stopReason === "error");
		assert.equal(errors.length, 1);
		await client.close();
	});

	test("a manual compaction places its summary while the conversation goes on", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Compacted" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		for (const text of ["one", "two", "three"]) {
			await client.request("conversation.submit", { conversationId: replica.id, requestId: `c-${text}`, content: `${text} ${"word ".repeat(80)}` });
			await until(replica, () => idle(replica) && replica.ordered().filter((entry) => entry.kind === "pi.assistant").length >= ["one", "two", "three"].indexOf(text) + 1);
		}
		await client.request("conversation.compact", { conversationId: replica.id });
		// The conversation takes a message while the summary is made.
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "c-during", content: "during" });
		await until(replica, () => kinds(replica).includes("pi.compaction") && idle(replica), 15_000);
		const compaction = replica.ordered().find((entry) => entry.kind === "pi.compaction")!;
		assert.match(JSON.stringify(compaction.model), /## Goal/);
		await client.close();
	});

	test("a fork with a request ID happens once", async () => {
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", { title: "Parent" });
		const id = dialog.conversation.id;
		await client.request("conversation.submit", { conversationId: id, requestId: "fork-parent", content: "hi" });
		const view = await client.request("conversation.subscribe", { conversationId: id });
		const at = Math.max(...view.entries.map((entry: { id: number }) => entry.id));
		const [a, b] = await Promise.all([
			client.request("conversation.fork", { conversationId: id, at, requestId: "fork-once" }),
			client.request("conversation.fork", { conversationId: id, at, requestId: "fork-once" }),
		]);
		assert.equal(a.dialog.conversation.id, b.dialog.conversation.id);
		assert.notEqual(a.dialog.conversation.id, id);
		await client.close();
	});
});

describe("durability", () => {
	const dir = mkdtempSync(join(tmpdir(), "tau-test-"));
	after(() => rmSync(dir, { recursive: true, force: true }));

	test("conversations and the server id survive a restart", async () => {
		const database = join(dir, "restart.sqlite");
		let { host, server } = await start({ database });
		const serverId = host.serverId;
		let client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await chat(client, replica, "remember me", "p");
		await client.close();
		await server.close();
		await host.close();

		({ host, server } = await start({ database }));
		assert.equal(host.serverId, serverId);
		client = await TauClient.connect(server.url);
		const hello = await client.request("hello", { protocol: 1 });
		assert.equal(hello.serverId, serverId);
		const before = replica.entries.size;
		await replica.sync(client);
		assert.equal(replica.entries.size, before, "nothing new to fetch");
		await chat(client, replica, "still there?", "q");
		assert.match(assistantText(replica.ordered().at(-1)), /turn 2/);
		await client.close();
		await server.close();
		await host.close();
	});

	test("a run killed mid-stream finishes after restart", async () => {
		const database = join(dir, "crash.sqlite");
		const port = 20_000 + Math.floor(Math.random() * 20_000);
		const launch = () =>
			spawn(process.execPath, ["--no-warnings", MAIN, "--db", database, "--port", String(port), "--dev-tps", "15"], {
				stdio: ["ignore", "pipe", "inherit"],
			});
		const ready = (child: ReturnType<typeof launch>) =>
			new Promise<void>((resolve) => child.stdout!.on("data", (data) => data.toString().includes("listening") && resolve()));
		const url = `ws://127.0.0.1:${port}`;

		let child = launch();
		await ready(child);
		let client = await TauClient.connect(url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "c", content: "survive this" });
		await until(replica, () => {
			const generation = (replica.docs["pi.live"] as { generation?: { message?: unknown } })?.generation;
			return generation?.message !== undefined;
		});
		child.kill("SIGKILL");
		await client.closed;

		child = launch();
		await ready(child);
		client = await TauClient.connect(url);
		await replica.sync(client);
		await until(replica, () => idle(replica) && replica.ordered().at(-1)?.kind === "pi.assistant", 20_000);
		assert.match(assistantText(replica.ordered().at(-1)), /You said: survive this/);
		await client.close();
		child.kill("SIGTERM");
	});
});
