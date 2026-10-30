import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";
import { failureNote } from "../src/subagent.ts";

const MAIN = join(import.meta.dirname, "..", "src", "main.ts");

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

function userText(entry: Entry): string {
	const content = (entry.model as { content: string | { type: string; text?: string }[] }[] | undefined)?.[0]?.content;
	return typeof content === "string" ? content : (content ?? []).map((part) => part.text ?? "").join("");
}

/** The reports of a subagent in its leader: `<subagent name="…" status="…">` messages. */
function reports(leader: ConversationReplica, status?: "answered" | "failed"): string[] {
	return leader
		.ordered()
		.filter((entry) => entry.kind === "pi.user")
		.map(userText)
		.filter((text) => text.startsWith("<subagent ") && (status === undefined || text.includes(`status="${status}"`)));
}

/** A leader that started the subagent `name`, and the subagent's conversation, both subscribed. */
async function started(client: TauClient, name: string, task: string): Promise<{ leader: ConversationReplica; child: ConversationReplica }> {
	const { dialog } = await client.request("conversation.create", {});
	const leader = new ConversationReplica(dialog.conversation.id);
	await leader.sync(client);
	await client.request("conversation.submit", { conversationId: leader.id, requestId: `spawn-${name}`, content: `& ${name}: ${task}` });
	let childId: number | undefined;
	await until(leader, () => {
		const result = leader.ordered().find((entry) => entry.kind === "pi.tool-result");
		childId = (result?.model as { details?: { conversationId?: number } }[] | undefined)?.[0]?.details?.conversationId;
		return childId !== undefined;
	});
	const child = new ConversationReplica(childId!);
	await child.sync(client);
	return { leader, child };
}

async function send(client: TauClient, replica: ConversationReplica, content: string, requestId: string, whenBusy?: "steer" | "followUp"): Promise<void> {
	await client.request("conversation.submit", { conversationId: replica.id, requestId, content, ...(whenBusy === undefined ? {} : { whenBusy }) });
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 1_500));

describe("subagent reports", () => {
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

	test("every run that answers reports to the leader, also one the user starts in the subagent's chat", async () => {
		const { leader, child } = await started(client, "helper", "first task");
		await until(leader, () => reports(leader, "answered").length === 1);
		assert.match(reports(leader)[0]!, /^<subagent name="helper" conversation="\d+" status="answered">\nYou said: first task/);
		await until(child, () => idle(child));
		// The user follows up in the subagent's own chat: its answer goes to the leader too.
		await send(client, child, "a question from the user", "user-1");
		await until(leader, () => reports(leader, "answered").length === 2);
		assert.match(reports(leader)[1]!, /You said: a question from the user/);
		await until(leader, () => idle(leader) && idle(child));
		await settle();
		assert.equal(reports(leader).length, 2, "each run once");
	});

	test("a steer joins the subagent's run, and its answer is reported once", async () => {
		const { leader, child } = await started(client, "worker", "$ sleep 2 && echo slept");
		await until(child, () => !idle(child));
		await send(client, child, "steer this way", "steer-1", "steer");
		await until(leader, () => reports(leader, "answered").length >= 1, 20_000);
		await until(leader, () => idle(leader) && idle(child), 20_000);
		await settle();
		const answered = reports(leader, "answered");
		assert.equal(answered.length, 1, answered.join("\n---\n"));
		assert.match(answered[0]!, /You said: steer this way/);
	});

	test("a failed run sends the leader a short note; a stopped one sends nothing", async () => {
		const { leader, child } = await started(client, "fragile", "hello");
		await until(leader, () => reports(leader, "answered").length === 1);
		await until(child, () => idle(child));
		await send(client, child, "!fatal broken", "fatal-1");
		await until(leader, () => reports(leader, "failed").length === 1);
		assert.match(reports(leader, "failed")[0]!, /fragile failed: the model failed \(401/);
		// Stopped while it works: no report, no note.
		await send(client, child, "$ sleep 5", "sleep-1");
		await until(child, () => !idle(child));
		await client.request("conversation.abort", { conversationId: child.id });
		await until(child, () => idle(child));
		await settle();
		assert.equal(reports(leader).length, 2, reports(leader).join("\n---\n"));
		assert.equal((child.docs["pi.live"] as { runFailure?: { reason: string } }).runFailure?.reason, "aborted");
	});

	test("the note says why in a few words, and nothing for a stop or a new context", () => {
		assert.equal(failureNote("helper", "interrupted", "x"), "helper failed: the server stopped while it was answering.");
		assert.equal(failureNote("helper", "turn_limit", "3 turns"), "helper failed: it reached its turn limit (3 turns).");
		assert.equal(failureNote("helper", "aborted", undefined), undefined);
		assert.equal(failureNote("helper", "reset", undefined), undefined);
	});
});

describe("subagent reports across restarts", () => {
	const dir = mkdtempSync(join(tmpdir(), "tau-subagent-"));
	after(() => rmSync(dir, { recursive: true, force: true }));

	test("a server killed while a subagent works reports its answer once after the restart, and a failure once", async () => {
		const database = join(dir, "crash.sqlite");
		const port = 20_000 + Math.floor(Math.random() * 20_000);
		const launch = () =>
			spawn(process.execPath, ["--no-warnings", MAIN, "--db", database, "--port", String(port), "--dev-tps", "15", "--cwd", tmpdir()], {
				stdio: ["ignore", "pipe", "inherit"],
			});
		const ready = (child: ReturnType<typeof launch>) =>
			new Promise<void>((resolve) => child.stdout!.on("data", (data) => data.toString().includes("listening") && resolve()));
		const url = `ws://127.0.0.1:${port}`;

		let server = launch();
		await ready(server);
		let client = await TauClient.connect(url);
		// Killed while the subagent's model is asked: the request counts as a failed attempt, and the retry answers.
		const { leader, child } = await started(client, "survivor", "~2 take your time");
		await until(child, () => !idle(child));
		await new Promise((resolve) => setTimeout(resolve, 500));
		server.kill("SIGKILL");
		await client.closed;

		server = launch();
		await ready(server);
		client = await TauClient.connect(url);
		await leader.sync(client);
		await child.sync(client);
		await until(leader, () => reports(leader, "answered").length >= 1, 60_000);
		await until(child, () => idle(child), 60_000);
		await until(leader, () => idle(leader), 60_000);

		// A failure, then a restart: the note is sent at once and again at start, under one request ID.
		await send(client, child, "!fatal broken", "fatal-restart");
		await until(leader, () => reports(leader, "failed").length === 1);
		await client.close();
		server.kill("SIGTERM");
		await new Promise((resolve) => server.on("exit", resolve));

		server = launch();
		await ready(server);
		client = await TauClient.connect(url);
		await leader.sync(client);
		await settle();
		await until(leader, () => idle(leader));
		assert.equal(reports(leader, "answered").length, 1, reports(leader).join("\n---\n"));
		assert.equal(reports(leader, "failed").length, 1, reports(leader).join("\n---\n"));
		await client.close();
		server.kill("SIGTERM");
	});
});
