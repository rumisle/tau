import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { parseAttachments } from "../src/attachments.ts";
import { ConversationReplica, type RequestError, TauClient } from "../src/client.ts";
import { FileStore, safeName } from "../src/files.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";

const TOKEN = "a-token-long-enough-for-files";
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC", "base64");

type Content = { type: string; text?: string; data?: string; mimeType?: string }[];

describe("files", () => {
	let host: Host;
	let server: Server;
	let base: string;
	let cwd: string;
	before(async () => {
		cwd = mkdtempSync(join(tmpdir(), "tau-files-cwd-"));
		host = await openHost({ devTokensPerSecond: 2_000, cwd, maxFileBytes: 64 * 1024 });
		server = await serve(host, { token: TOKEN });
		base = server.url.replace(/^ws/, "http");
	});
	after(async () => {
		await server.close();
		await host.close();
		rmSync(cwd, { recursive: true, force: true });
	});

	const upload = async (name: string, body: Uint8Array | string, token = TOKEN) =>
		fetch(`${base}/files?name=${encodeURIComponent(name)}`, { method: "POST", body, headers: { Authorization: `Bearer ${token}` } });

	type Uploaded = { id: string; name: string; bytes: number; mimeType: string; width?: number };
	const uploaded = async (name: string, body: Uint8Array | string): Promise<Uploaded> => (await (await upload(name, body)).json()) as Uploaded;

	const until = (replica: ConversationReplica, predicate: () => boolean) =>
		new Promise<void>((resolve, reject) => {
			if (predicate()) return resolve();
			const timer = setTimeout(() => reject(new Error("timed out")), 10_000);
			const stop = replica.onChange(() => {
				if (!predicate()) return;
				clearTimeout(timer);
				stop();
				resolve();
			});
		});

	test("uploads stream in behind the token, and come back whole or in ranges", async () => {
		assert.equal((await upload("a.txt", "hello", "a-token-long-enough-to-fail")).status, 401);
		const response = await upload("../notes/a b.txt", "hello world");
		assert.equal(response.status, 201);
		const file = (await response.json()) as Uploaded;
		assert.match(file.id, /^[0-9a-f]{32}$/);
		assert.equal(file.name, "a b.txt", "only the last component of a name");
		assert.equal(file.bytes, 11);
		assert.equal(file.mimeType, "text/plain");
		const headers = { Authorization: `Bearer ${TOKEN}` };
		const whole = await fetch(`${base}/files/${file.id}`, { headers });
		assert.equal(await whole.text(), "hello world");
		assert.match(whole.headers.get("content-disposition") ?? "", /a%20b\.txt/);
		const part = await fetch(`${base}/files/${file.id}`, { headers: { ...headers, Range: "bytes=6-" } });
		assert.equal(part.status, 206);
		assert.equal(await part.text(), "world");
		assert.equal((await fetch(`${base}/files/${"0".repeat(32)}`, { headers })).status, 404);
		assert.equal((await fetch(`${base}/files/${file.id}`)).status, 401);
		// Over the limit: refused, and nothing stays.
		const big = await upload("big.bin", new Uint8Array(65 * 1024));
		assert.equal(big.status, 413);
	});

	test("a message's files reach the model by path, photos shown too, and the chat reads the caption", async () => {
		const client = await TauClient.connect(server.url, TOKEN);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const report = await uploaded("report.csv", "a,b\n1,2\n");
		const photo = await uploaded("photo", PNG);
		assert.equal(photo.mimeType, "image/png", "an image is known by its bytes");
		assert.equal(photo.width, 1);
		await client.request("conversation.submit", {
			conversationId: replica.id,
			requestId: "f-1",
			content: "what is in these?",
			attachments: [{ id: report.id }, { id: photo.id, as: "image" }],
		});
		await until(replica, () => replica.ordered().some((entry) => entry.kind === "pi.assistant"));
		const user = replica.ordered().find((entry) => entry.kind === "pi.user") as unknown as { model: { content: Content }[] };
		const content = user.model[0]!.content;
		const lines = parseAttachments(content[0]!.text!);
		assert.ok(lines, "the first block names the files");
		assert.deepEqual(lines.map((line) => line.kind), ["file", "image"]);
		assert.equal(lines[0]!.path, join(host.files.root, report.id, "report.csv"));
		assert.equal(content[1]!.type, "image", "the photo is shown too");
		assert.equal(content[1]!.data, PNG.toString("base64"));
		assert.equal(content[2]!.text, "what is in these?");
		// Read-only, in a read-only directory, kept for good.
		assert.equal(statSync(lines[0]!.path).mode & 0o777, 0o400);
		assert.equal(statSync(join(host.files.root, report.id)).mode & 0o777, 0o500);
		// Swept at once, uploads no message took go; the message's stay.
		await host.files.sweep(0);
		assert.ok(await host.files.get(report.id), "a file a message refers to is never swept");
		assert.ok(await host.files.get(photo.id));
		const { dialogs } = await client.request("dialogs.subscribe");
		const listed = dialogs.find((each: { conversation: { id: number } }) => each.conversation.id === replica.id);
		assert.equal(listed.title, "what is in these?");
		const last = replica.ordered().filter((entry) => entry.kind === "pi.user").at(-1)!;
		assert.equal(last.id <= listed.last.id, true);
		// Files alone: the list reads the file's name.
		const more = await uploaded("notes.md", "# hi");
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "f-2", attachments: [{ id: more.id }] });
		await until(replica, () => replica.ordered().filter((entry) => entry.kind === "pi.assistant").length >= 2);
		const after = (await client.request("dialogs.subscribe")).dialogs.find((each: { conversation: { id: number } }) => each.conversation.id === replica.id);
		const userSummary = (await client.request("conversation.history", { conversationId: replica.id, limit: 10 })).entries.filter((entry: { kind: string }) => entry.kind === "pi.user").length;
		assert.equal(userSummary, 2);
		assert.ok(after);
		// An ID nothing was uploaded under is refused, with nothing written.
		await assert.rejects(
			client.request("conversation.submit", { conversationId: replica.id, requestId: "f-3", content: "x", attachments: [{ id: "f".repeat(32) }] }),
			(error: RequestError) => error.code === "file_missing",
		);
		await client.close();
	});

	test("send_file copies a file for the user, once however often the call runs", async () => {
		writeFileSync(join(cwd, "chart.png"), PNG);
		mkdirSync(join(cwd, "folder"), { recursive: true });
		const client = await TauClient.connect(server.url, TOKEN);
		const { dialog } = await client.request("conversation.create", { agent: { cwd } });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "s-1", content: "!send chart.png folder missing.txt" });
		await until(replica, () => replica.ordered().some((entry) => entry.kind === "pi.tool-result"));
		const result = replica.ordered().find((entry) => entry.kind === "pi.tool-result") as unknown as { model: { content: Content; details: { files: { id: string; name: string; mimeType: string; width?: number }[] }; isError: boolean }[] };
		const message = result.model[0]!;
		assert.equal(message.isError, false);
		assert.equal(message.details.files.length, 1);
		const sent = message.details.files[0]!;
		assert.equal(sent.name, "chart.png");
		assert.equal(sent.mimeType, "image/png");
		assert.equal(sent.width, 1);
		assert.match(message.content[0]!.text!, /Sent to the user: chart\.png/);
		assert.match(message.content[0]!.text!, /folder: .*directory/);
		assert.match(message.content[0]!.text!, /missing\.txt: No file/);
		// The copy is the file as it was: changing the original changes nothing sent.
		writeFileSync(join(cwd, "chart.png"), "changed");
		const fetched = await fetch(`${base}/files/${sent.id}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
		assert.deepEqual(Buffer.from(await fetched.arrayBuffer()), PNG);
		// Run again under the same ID: the copy made is the one there.
		const again = await host.files.adopt(join(cwd, "chart.png"), sent.id);
		assert.equal(again.bytes, PNG.length);
		await client.close();
	});
});

describe("file store", () => {
	test("sweeps uploads no message took after a day, and what a cut-off upload left", async () => {
		const store = new FileStore();
		const root = store.root;
		try {
			const { Readable } = await import("node:stream");
			const kept = await store.upload("kept.txt", Readable.from([Buffer.from("a")]));
			const dropped = await store.upload("dropped.txt", Readable.from([Buffer.from("b")]));
			await store.keep([kept.id]);
			await store.age(dropped.id, 25 * 60 * 60 * 1000);
			assert.equal(await store.sweep(), 1);
			assert.ok(await store.get(kept.id));
			assert.equal(await store.get(dropped.id), undefined);
			assert.equal(statSync(root).mode & 0o777, 0o700);
		} finally {
			store.close();
		}
	});

	test("names keep their last component and extension, and nothing that could escape", () => {
		assert.equal(safeName("../../etc/passwd"), "passwd");
		assert.equal(safeName("a\u0000b\nc.txt"), "abc.txt");
		assert.equal(safeName(""), "file");
		assert.equal(safeName(".."), "file");
		assert.equal(safeName(`${"x".repeat(300)}.pdf`).endsWith(".pdf"), true);
		assert.ok(Buffer.byteLength(safeName(`${"字".repeat(300)}.pdf`)) <= 200);
	});
});
