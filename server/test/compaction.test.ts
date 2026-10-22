import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import type { Message } from "@earendil-works/pi-ai";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { answered, type CompactionUsage, compactionPolicy, DEFAULT_COMPACTION_THRESHOLD } from "../src/compaction.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";
import { formatSkills, loadSkills, parseSkill } from "../src/skills.ts";

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

const idle = (replica: ConversationReplica) => (replica.docs["pi.live"] as { run?: unknown; compactions?: unknown } | undefined)?.run === undefined;
const settled = (replica: ConversationReplica) => idle(replica) && (replica.docs["pi.live"] as { compactions?: unknown } | undefined)?.compactions === undefined;
const ofKind = (replica: ConversationReplica, kind: string) => replica.ordered().filter((entry) => entry.kind === kind);
const text = (entry: Entry) => JSON.stringify(entry.model);

async function chat(client: TauClient, replica: ConversationReplica, content: string, requestId: string, timeoutMs?: number): Promise<void> {
	const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId, content });
	await until(replica, () => replica.submissions.get(submission.id)?.status === "done" && idle(replica), timeoutMs);
}

function skill(dir: string, name: string, description: string, extra = ""): void {
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "SKILL.md"), `---\nname: ${name}\ndescription: ${description}\n${extra}---\n\n# ${name}\n`);
}

describe("compaction thresholds", () => {
	test("start at 90% of the window, at most 700k, with durable's blocking threshold behind", () => {
		const reserve = 16_384;
		assert.deepEqual(compactionPolicy(200_000, DEFAULT_COMPACTION_THRESHOLD), { enabled: true, reserveTokens: reserve, backgroundTokens: 200_000 - reserve - 180_000 });
		assert.deepEqual(compactionPolicy(1_000_000, DEFAULT_COMPACTION_THRESHOLD), { enabled: true, reserveTokens: reserve, backgroundTokens: 1_000_000 - reserve - 700_000 });
		// A window too small for 90% to come before the blocking threshold only blocks.
		assert.deepEqual(compactionPolicy(32_000, DEFAULT_COMPACTION_THRESHOLD), { enabled: true, reserveTokens: reserve, backgroundTokens: 0 });
		assert.deepEqual(compactionPolicy(200_000, { ...DEFAULT_COMPACTION_THRESHOLD, enabled: false }), { enabled: false });
	});

	test("the follow-up leaves out a tool round still waiting for results", () => {
		const user = (text: string): Message => ({ role: "user", content: text, timestamp: 0 });
		const call = (id: string): Message => ({ role: "assistant", content: [{ type: "toolCall", id, name: "bash", arguments: {} }], api: "x", provider: "x", model: "x", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "toolUse", timestamp: 0 }) as Message;
		const result = (id: string): Message => ({ role: "toolResult", toolCallId: id, toolName: "bash", content: [{ type: "text", text: "ok" }], isError: false, timestamp: 0 });
		const done = [user("a"), call("1"), result("1"), user("b")];
		assert.deepEqual(answered(done), done);
		assert.deepEqual(answered([...done, call("2")]), done);
		assert.deepEqual(answered([...done, call("2"), user("steer")]), done);
	});
});

describe("skills", () => {
	let home: string;
	let project: string;
	before(() => {
		home = mkdtempSync(join(tmpdir(), "tau-skills-home-"));
		project = mkdtempSync(join(tmpdir(), "tau-skills-project-"));
		skill(join(home, ".agents", "skills", "zeta"), "zeta", "Last by name.");
		skill(join(home, ".agents", "skills", "group", "alpha"), "alpha", "In a subdirectory, & escaped <here>.");
		skill(join(home, ".agents", "skills", "hidden"), "hidden", "Not for the model.", "disable-model-invocation: true\n");
		skill(join(project, ".agents", "skills", "zeta"), "zeta", "The project's, which the user's wins over.");
		skill(join(project, ".agents", "skills", "beta"), "beta", "The project's own.");
		// A link to a skill already listed counts once.
		symlinkSync(join(home, ".agents", "skills", "zeta"), join(project, ".agents", "skills", "zeta-link"));
		mkdirSync(join(home, ".agents", "skills", "empty"));
	});
	after(() => {
		rmSync(home, { recursive: true, force: true });
		rmSync(project, { recursive: true, force: true });
	});

	test("are found in .agents/skills, sorted, the user's first for a name both have", () => {
		const skills = loadSkills(project, home);
		assert.deepEqual(
			skills.map((each) => [each.name, each.description]),
			[
				["alpha", "In a subdirectory, & escaped <here>."],
				["beta", "The project's own."],
				["zeta", "Last by name."],
			],
		);
		const prompt = formatSkills(skills)!;
		assert.match(prompt, /<name>alpha<\/name>\n {4}<description>In a subdirectory, &amp; escaped &lt;here&gt;\.<\/description>/);
		assert.match(prompt, new RegExp(`<location>${join(home, ".agents", "skills", "group", "alpha", "SKILL.md")}</location>`));
		assert.equal(formatSkills([]), undefined);
	});

	test("need front matter with a description, and take the directory's name without one", () => {
		assert.equal(parseSkill("# no front matter", "/s/x/SKILL.md"), undefined);
		assert.equal(parseSkill("---\nname: x\n---\n", "/s/x/SKILL.md"), undefined);
		assert.deepEqual(parseSkill("---\ndescription: >\n  Folded\n  text.\n---\n", "/s/dir-name/SKILL.md"), { name: "dir-name", description: "Folded text.", filePath: "/s/dir-name/SKILL.md" });
	});

	test("reach the prompt as one system delta when they change, and none when they do not", async () => {
		const host = await openHost({ devTokensPerSecond: 20_000, cwd: project, skillsHome: home });
		const server = await serve(host);
		try {
			const client = await TauClient.connect(server.url);
			const { dialog } = await client.request("conversation.create", { cwd: project });
			const replica = new ConversationReplica(dialog.conversation.id);
			await replica.sync(client);
			await chat(client, replica, "one", "s1");
			const first = ofKind(replica, "pi.system");
			assert.ok(first.some((entry) => text(entry).includes("<name>beta</name>")), "the skills are in the prompt");
			await chat(client, replica, "two", "s2");
			assert.equal(ofKind(replica, "pi.system").length, first.length, "the same skills add nothing");
			skill(join(project, ".agents", "skills", "gamma"), "gamma", "Added between two messages.");
			await chat(client, replica, "three", "s3");
			const after = ofKind(replica, "pi.system");
			assert.equal(after.length, first.length + 1, "one delta");
			assert.match(text(after.at(-1)!), /<name>gamma<\/name>/);
			await chat(client, replica, "four", "s4");
			assert.equal(ofKind(replica, "pi.system").length, after.length);
			await client.close();
		} finally {
			await server.close();
			await host.close();
		}
	});
});

describe("follow-up compaction", () => {
	let host: Host;
	let server: Server;
	const usages: CompactionUsage[] = [];
	before(async () => {
		// A cache lifetime gives the dev model a prompt cache per provider session, with prices.
		host = await openHost({ devTokensPerSecond: 1_000_000, devCacheTtl: 300, cwd: tmpdir(), skillsHome: tmpdir() });
		host.compaction.onUsage((usage) => usages.push(usage));
		server = await serve(host);
	});
	after(async () => {
		await server.close();
		await host.close();
	});

	async function conversation(client: TauClient): Promise<ConversationReplica> {
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		return replica;
	}

	test("asks for the summary after the cached context, so it reads it from the cache", async () => {
		const client = await TauClient.connect(server.url);
		const replica = await conversation(client);
		for (const word of ["one", "two", "three"]) await chat(client, replica, `!quiet ${word} ${"lorem ipsum dolor sit amet ".repeat(2_000)}`, `f-${word}`);
		const before = usages.length;
		await client.request("conversation.compact", { conversationId: replica.id, instructions: "the third message" });
		await until(replica, () => ofKind(replica, "pi.compaction").length === 1 && settled(replica));
		const compaction = ofKind(replica, "pi.compaction")[0]!;
		assert.match(text(compaction), /compacted into the following summary/);
		assert.match(text(compaction), /## Goal/);
		const usage = usages.slice(before);
		assert.equal(usage.length, 1, "one follow-up");
		assert.equal(usage[0]!.conversationId, replica.id);
		assert.ok(usage[0]!.usage.cacheRead > 1_000, `read ${usage[0]!.usage.cacheRead} from the cache`);
		// What is new is the prompt and the last answer, which no request has sent yet.
		assert.ok(usage[0]!.usage.cacheRead > 10 * usage[0]!.usage.input, `mostly read: ${JSON.stringify(usage[0]!.usage)}`);
		// The ledger has it as a model of its own, not as an answer.
		const report = (await client.request("usage.report", { days: 1 })) as { models: { model: string; replies: number }[] };
		assert.ok((report.models.find((each) => each.model === "tau/compaction")?.replies ?? 0) >= 1);
		// The conversation goes on after it.
		await chat(client, replica, "after", "f-after");
		await client.close();
	});

	test("falls back to durable's own summary when the follow-up gives none", async () => {
		const client = await TauClient.connect(server.url);
		const replica = await conversation(client);
		for (const word of ["one", "two", "three"]) await chat(client, replica, `${word} !no-follow-up ${"word ".repeat(80)}`, `n-${word}`);
		const before = usages.length;
		await client.request("conversation.compact", { conversationId: replica.id });
		await until(replica, () => ofKind(replica, "pi.compaction").length === 1 && settled(replica));
		assert.match(text(ofKind(replica, "pi.compaction")[0]!), /## Goal/);
		assert.equal(usages.length - before, 1, "the follow-up was tried once: a tool call is no error that may pass");
		await client.close();
	});

	test("starts on its own at the threshold set, and the conversation goes on", async () => {
		const client = await TauClient.connect(server.url);
		await client.request("hello", { protocol: 1 });
		// The dev model's window is 200k: compaction starts above 60k tokens.
		const { compaction } = (await client.request("settings.configure", { compaction: { ratio: 0.3 } })) as { compaction: { enabled: boolean; ratio: number; maxTokens: number } };
		assert.deepEqual(compaction, { enabled: true, ratio: 0.3, maxTokens: 700_000 });
		await assert.rejects(client.request("settings.configure", { compaction: { ratio: 2 } }));
		try {
			const replica = await conversation(client);
			await chat(client, replica, "small", "t-small");
			assert.equal(ofKind(replica, "pi.compaction").length, 0);
			// About 70k tokens.
			await chat(client, replica, `!quiet big ${"lorem ipsum dolor sit amet ".repeat(10_000)}`, "t-big", 60_000);
			await until(replica, () => ofKind(replica, "pi.compaction").length >= 1 && settled(replica), 30_000);
			assert.equal((ofKind(replica, "pi.compaction")[0]!.data as { reason?: string } | undefined)?.reason, "threshold");
			await chat(client, replica, "next", "t-next");
		} finally {
			await client.request("settings.configure", { compaction: { ratio: 0.9 } });
			await client.close();
		}
	});
});
