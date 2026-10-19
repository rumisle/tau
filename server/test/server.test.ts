import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, type Entry, type Push, RequestError, TauClient } from "../src/client.ts";
import { type Host, openHost } from "../src/host.ts";
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
