import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
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

	test("the client picks a conversation's cwd by browsing the server", async () => {
		const project = mkdtempSync(join(tmpdir(), "tau-project-"));
		mkdirSync(join(project, "repo", ".git"), { recursive: true });
		writeFileSync(join(project, "notes.txt"), "hi");
		mkdirSync(join(project, ".hidden"));
		try {
			const client = await TauClient.connect(server.url);
			const hello = await client.request("hello", { protocol: 1 });
			assert.equal(hello.home, homedir());
			assert.equal((await client.request("fs.list")).path, homedir());

			const listing = await client.request("fs.list", { path: project });
			assert.equal(listing.path, project);
			assert.deepEqual(listing.entries, [
				{ name: "repo", kind: "dir", git: true },
				{ name: "notes.txt", kind: "file" },
			]);
			assert.ok((await client.request("fs.list", { path: project, hidden: true })).entries.some((e: { name: string }) => e.name === ".hidden"));
			assert.equal(listing.parent, dirname(project));
			await assert.rejects(client.request("fs.list", { path: join(project, "nope") }), (e: RequestError) => e.code === "bad_request");
			await assert.rejects(client.request("fs.list", { path: "relative/dir" }), (e: RequestError) => e.code === "bad_request");

			// Create in the picked directory; the tools run there.
			const repo = join(project, "repo");
			const { dialog } = await client.request("conversation.create", { agent: { cwd: repo } });
			assert.equal(dialog.agent.cwd, repo);
			const replica = new ConversationReplica(dialog.conversation.id);
			await replica.sync(client);
			await chat(client, replica, "$ pwd", "pwd");
			assert.equal(realpathSync(assistantText(replica.ordered().at(-1)).match(/```\n(.*)\n```/)![1]!), realpathSync(repo));

			// A missing directory is refused; a change shows in the dialog.
			await assert.rejects(
				client.request("conversation.configure", { conversationId: replica.id, agent: { cwd: join(project, "gone") } }),
				(e: RequestError) => e.code === "bad_request",
			);
			const pushed = new Promise<{ agent: { cwd: string } }>((resolve) =>
				client.on((push) => {
					const d = push.dialog as { conversation: { id: number }; agent: { cwd: string } } | undefined;
					if (push.event === "dialog" && d?.conversation.id === replica.id) resolve(d);
				}),
			);
			await client.request("dialogs.subscribe");
			await client.request("conversation.configure", { conversationId: replica.id, agent: { cwd: project } });
			assert.equal((await pushed).agent.cwd, project);
			await client.close();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
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
		const image = { type: "image", data: "A".repeat(8 * 1024 * 1024), mimeType: "image/jpeg" };
		await assert.rejects(
			client.request("conversation.submit", { conversationId: id, requestId: "img", content: [image] }),
			(error: RequestError) => error.code === "too_large",
		);
		await assert.rejects(
			client.request("conversation.submit", { conversationId: id, requestId: "tiff", content: [{ type: "image", data: "AAAA", mimeType: "image/tiff" }] }),
			(error: RequestError) => error.code === "unsupported",
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

	test("an answer is pushed through ntfy only while no app is in the foreground", async () => {
		const posts: unknown[] = [];
		server.notifier.post = async (_url, body) => {
			posts.push(body);
		};
		const client = await TauClient.connect(server.url);
		await client.request("hello", { protocol: 1 });
		await client.request("settings.configure", { ntfy: { server: "https://ntfy.example", topic: "tau-test" } });
		const run = async (text: string) => {
			const { dialog } = await client.request("conversation.create", { title: "Pushed" });
			const replica = new ConversationReplica(dialog.conversation.id);
			await replica.sync(client);
			await client.request("conversation.submit", { conversationId: replica.id, requestId: `push-${text}`, content: text });
			await until(replica, () => idle(replica) && kinds(replica).includes("pi.assistant"));
			await new Promise((resolve) => setTimeout(resolve, 50));
			return replica.id;
		};
		await client.request("client.presence", { active: true });
		await run("seen in the app");
		assert.equal(posts.length, 0);
		await client.request("client.presence", { active: false });
		const id = await run("away");
		assert.equal(posts.length, 1);
		assert.match(JSON.stringify(posts[0]), new RegExp(`tau://chat\\?server=[^&]+&id=${id}`));
		await client.request("settings.configure", { ntfy: null });
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
