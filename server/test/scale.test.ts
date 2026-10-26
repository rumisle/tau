// What keeps a large server quick: titles indexed once, usage summed a span at a time, the chat list sent as kept.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, describe, test } from "node:test";
import { WebSocket } from "ws";
import { ConversationReplica, TauClient } from "../src/client.ts";
import { openHost } from "../src/host.ts";
import { Kind, SearchIndex } from "../src/search/index.ts";
import { UsageLedger } from "../src/search/usage.ts";
import { serve } from "../src/server.ts";

const dir = mkdtempSync(join(tmpdir(), "tau-scale-"));
after(() => rmSync(dir, { recursive: true, force: true }));

const changes = (index: SearchIndex) => (index.db.prepare("SELECT total_changes() AS n").get() as { n: number }).n;
const noText = async () => undefined;

describe("search index titles", () => {
	test("a title offered again writes nothing, also after a restart", async () => {
		const path = join(dir, "titles.search.db");
		let index = new SearchIndex(path);
		index.setTitle(1, "Wombat burrows");
		index.setTitle(2, "");
		index.close();

		index = new SearchIndex(path);
		const before = changes(index);
		index.setTitle(1, "Wombat burrows");
		index.setTitle(2, "");
		assert.equal(changes(index), before, "the same titles: no write");
		index.setTitle(1, "Echidna spines");
		assert.ok(changes(index) > before, "a new title is written");
		assert.equal((await index.search("echidna", noText)).total, 1);
		assert.equal((await index.search("wombat", noText)).total, 0, "the old title is gone");
		index.close();
	});

	test("an index of version 3 keeps its rows and learns its titles", async () => {
		const path = join(dir, "v3.search.db");
		let index = new SearchIndex(path);
		index.add([{ conversationId: 7, entryId: 70, time: Date.now(), parts: [{ kind: Kind.user, text: "platypus eggs", idx: 0 }] }]);
		index.setTitle(7, "Monotremes");
		index.close();
		// As version 3 left it: no title column.
		const db = new DatabaseSync(path);
		db.exec("ALTER TABLE conv DROP COLUMN title");
		db.exec("PRAGMA user_version = 3");
		db.close();

		index = new SearchIndex(path);
		assert.equal((await index.search("platypus", noText)).total, 1, "entries kept, not indexed again");
		assert.equal(index.cursor(7), 70);
		index.setTitle(7, "Monotremes");
		const once = changes(index);
		index.setTitle(7, "Monotremes");
		assert.equal(changes(index), once, "written once, then known");
		assert.equal((await index.search("monotremes", noText)).total, 1);
		index.close();
	});
});

describe("search backfill", () => {
	test("a file's index is made again by the worker, and this thread goes on writing it", async () => {
		const database = join(dir, "backfill", "tau.db");
		const open = async () => {
			const host = await openHost({ database, devTokensPerSecond: 20_000, cwd: tmpdir() });
			return { host, server: await serve(host) };
		};
		const say = async (url: string, id: number | undefined, text: string) => {
			const client = await TauClient.connect(url);
			const conversationId = id ?? (await client.request("conversation.create", { title: "Numbat termites" })).dialog.conversation.id;
			const replica = new ConversationReplica(conversationId);
			await replica.sync(client);
			const { submission } = await client.request("conversation.submit", { conversationId, requestId: text, content: text });
			await waitFor(() => replica.submissions.get(submission.id)?.status === "done");
			await client.close();
			return conversationId;
		};
		const found = async (url: string, query: string) => {
			const client = await TauClient.connect(url);
			const response = await client.request("search", { query });
			await client.close();
			return response.results.map((result: { conversationId: number }) => result.conversationId);
		};
		let { host, server } = await open();
		const id = await say(server.url, undefined, "quoll first");
		await server.close();
		await host.close();
		// Without its index: the next start indexes everything again.
		for (const suffix of ["", "-wal", "-shm"]) rmSync(join(dir, "backfill", `tau.search.db${suffix}`), { force: true });
		({ host, server } = await open());
		try {
			assert.deepEqual(await found(server.url, "quoll"), [id]);
			assert.deepEqual(await found(server.url, "numbat"), [id], "the title too");
			await say(server.url, id, "bilby second");
			await new Promise((resolve) => setTimeout(resolve, 50));
			assert.deepEqual(await found(server.url, "bilby"), [id], "written after the backfill");
			assert.deepEqual(await found(server.url, "quoll"), [id], "the backfill's rows kept");
		} finally {
			await server.close();
			await host.close();
		}
	});
});

describe("usage report", () => {
	test("summed a span at a time, it is what one pass over all of it gives, and lets others run", async () => {
		const db = new DatabaseSync(":memory:");
		const ledger = new UsageLedger(db);
		const now = Date.UTC(2026, 9, 21, 12);
		const DAY = 86_400_000;
		const rows = [];
		// More rows than one span, over 90 days, three models, 50 conversations; costs exact in binary.
		for (let i = 0; i < 45_000; i++) {
			rows.push({
				entryId: i + 1,
				conversationId: (i * 7) % 50,
				time: now - Math.floor((i / 45_000) * 90 * DAY) - (i % 13) * 60_000,
				model: ["a/x", "b/y", "c/z"][i % 3]!,
				input: i % 100,
				output: i % 37,
				cacheRead: i % 1000,
				cacheWrite: i % 11,
				cost: (i % 8) / 4,
			});
		}
		ledger.add(rows);
		for (let i = 0; i < 30; i++) {
			ledger.addWarm({ conversationId: i, time: now - i * DAY, input: 1, output: 1, cacheRead: 100, cacheWrite: 0, cost: 0.25 });
			ledger.addCompaction({ conversationId: i, time: now - i * 2 * DAY, input: 50, output: 5, cacheRead: 0, cacheWrite: 0, cost: 0.5 });
		}
		for (const [days, tzOffset] of [[0, 0], [30, 120], [7, -330], [1, 345]] as const) {
			let others = 0;
			const ticking = setInterval(() => (others += 1), 0);
			const report = await ledger.report(days, tzOffset, now);
			clearInterval(ticking);
			assert.deepEqual(report, reference(db, days, tzOffset, now), `days ${days}, tz ${tzOffset}`);
			if (days === 0) assert.ok(others > 0, "timers ran while it summed");
		}
		db.close();
	});
});

/** The report as one pass of SQL makes it, as it was made before it was summed a span at a time. */
function reference(db: DatabaseSync, days: number, tzOffset: number, now: number) {
	const DAY = 86_400_000;
	const shift = tzOffset * 60_000;
	const today = Math.floor((now + shift) / DAY);
	const first = days > 0 ? today - days + 1 : Math.floor((((db.prepare("SELECT min(time) AS t FROM spend").get() as { t: number | null }).t ?? now) + shift) / DAY);
	const since = first * DAY - shift;
	const span = (today - first + 1) * DAY;
	const sums = "sum(cost) AS cost, sum(input) AS input, sum(output) AS output, sum(cache_read) AS cacheRead, sum(cache_write) AS cacheWrite, sum(answer) AS replies";
	const totals = (row: any) => ({ cost: row.cost ?? 0, input: row.input ?? 0, output: row.output ?? 0, cacheRead: row.cacheRead ?? 0, cacheWrite: row.cacheWrite ?? 0, replies: row.replies ?? 0 });
	const daysOut: { day: string; models: Record<string, ReturnType<typeof totals>> }[] = [];
	for (let day = first; day <= today; day++) daysOut.push({ day: new Date(day * DAY).toISOString().slice(0, 10), models: {} });
	for (const row of db.prepare(`SELECT CAST((time + ?) / ${DAY} AS INTEGER) AS day, model, ${sums} FROM spend WHERE time >= ? GROUP BY day, model`).all(shift, since) as any[]) {
		const slot = daysOut[row.day - first];
		if (slot !== undefined) slot.models[row.model] = totals(row);
	}
	const models = (db.prepare(`SELECT model, ${sums.replace("sum(answer)", "count(*)")} FROM spend WHERE time >= ? GROUP BY model ORDER BY cost DESC, model`).all(since) as any[]).map((row) => ({ model: row.model, ...totals(row) }));
	const conversations = (db.prepare(`SELECT conv AS conversationId, ${sums} FROM spend WHERE time >= ? GROUP BY conv ORDER BY cost DESC, conv`).all(since) as any[]).map((row) => ({ conversationId: row.conversationId, ...totals(row) }));
	const all = db.prepare(`SELECT ${sums}, count(DISTINCT conv) AS conversations FROM spend WHERE time >= ?`).get(since) as any;
	const previous = db.prepare(`SELECT ${sums} FROM spend WHERE time >= ? AND time < ?`).get(since - span, since);
	const top = conversations.slice(0, 20);
	return { days: daysOut, models, conversations: top, total: { ...totals(all), conversations: all.conversations ?? 0 }, previous: totals(previous) };
}

describe("chat list", () => {
	test("sent as kept: the frame is the list as JSON, unread counts past the first entries", async () => {
		const host = await openHost({ devTokensPerSecond: 20_000, cwd: tmpdir() });
		const server = await serve(host);
		try {
			const client = await TauClient.connect(server.url);
			const { dialog } = await client.request("conversation.create", { title: "Many answers" });
			const replica = new ConversationReplica(dialog.conversation.id);
			await replica.sync(client);
			for (let i = 0; i < 4; i++) {
				const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: `m-${i}`, content: `$ echo ${i}` });
				await waitFor(() => replica.submissions.get(submission.id)?.status === "done");
			}
			// Read up to the first answer: the unread ones are further back than the first few entries.
			const firstAnswer = replica.ordered().find((entry) => entry.kind === "pi.assistant")!;
			await client.request("conversation.read", { conversationId: replica.id, at: firstAnswer.id });
			const listed = (await client.request("dialogs.subscribe", {})).dialogs.find((each: { conversation: { id: number } }) => each.conversation.id === replica.id);
			const answers = replica.ordered().filter((entry) => entry.id > firstAnswer.id && entry.kind === "pi.assistant" && JSON.stringify(entry.model).includes('"type":"text"'));
			assert.equal(listed.unreadCount, answers.length);
			assert.ok(listed.unreadCount >= 4);
			await client.close();

			const socket = new WebSocket(server.url);
			await new Promise((resolve) => socket.once("open", resolve));
			const frames: string[] = [];
			socket.on("message", (data) => frames.push(data.toString()));
			socket.send(JSON.stringify({ id: 1, method: "hello", params: { protocol: 1 } }));
			socket.send(JSON.stringify({ id: "list", method: "dialogs.subscribe", params: {} }));
			await waitFor(() => frames.length >= 2);
			const frame = frames[1]!;
			const parsed = JSON.parse(frame);
			assert.equal(parsed.id, "list");
			assert.equal(frame, JSON.stringify({ id: "list", result: parsed.result }), "the frame #push would have sent");
			socket.close();
		} finally {
			await server.close();
			await host.close();
		}
	});
});

async function waitFor(predicate: () => boolean, timeoutMs = 10_000): Promise<void> {
	const started = Date.now();
	while (!predicate()) {
		if (Date.now() - started > timeoutMs) throw new Error("timed out");
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
}
