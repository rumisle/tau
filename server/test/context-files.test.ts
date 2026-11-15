import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { SystemEntry, type ConversationId } from "@earendil-works/pi-durable";
import { ConversationReplica, TauClient } from "../src/client.ts";
import { loadContextFiles } from "../src/context-files.ts";
import { openHost } from "../src/host.ts";
import { serve } from "../src/server.ts";

function fixture(t: { after(fn: () => void): void }) {
	const root = mkdtempSync(join(tmpdir(), "tau-context-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const agent = join(root, "global");
	const project = join(root, "repo");
	const cwd = join(project, "nested");
	mkdirSync(agent, { recursive: true });
	mkdirSync(cwd, { recursive: true });
	return { root, agent, project, cwd };
}

test("context files: global first, ancestors before cwd; first candidate in each directory", (t) => {
	const { agent, project, cwd } = fixture(t);
	writeFileSync(join(agent, "AGENTS.md"), "global");
	writeFileSync(join(project, "AGENTS.override.md"), "override");
	writeFileSync(join(project, "AGENTS.md"), "not selected");
	writeFileSync(join(cwd, "CLAUDE.md"), "nested");
	assert.deepEqual(loadContextFiles(cwd, agent).map((file) => file.content), ["global", "override", "nested"]);
});

test("context files: follow symlinks, strip BOM and deduplicate real files", (t) => {
	const { agent, project, cwd } = fixture(t);
	const file = join(agent, "AGENTS.md");
	writeFileSync(file, "\uFEFFglobal");
	symlinkSync(file, join(project, "AGENTS.md"));
	assert.deepEqual(loadContextFiles(cwd, agent).map((file) => file.content), ["global"]);
});

test("context files: modifications and deletions are visible on the next render", (t) => {
	const { agent, project, cwd } = fixture(t);
	const file = join(project, "AGENTS.md");
	writeFileSync(file, "first");
	assert.equal(loadContextFiles(cwd, agent).at(-1)?.content, "first");
	writeFileSync(file, "second");
	assert.equal(loadContextFiles(cwd, agent).at(-1)?.content, "second");
	rmSync(file);
	assert.equal(loadContextFiles(cwd, agent).length, 0);
});

test("context files: project-local .agents/AGENTS.md is not a rule source", (t) => {
	const { agent, project, cwd } = fixture(t);
	mkdirSync(join(project, ".agents"));
	writeFileSync(join(project, ".agents", "AGENTS.md"), "not loaded");
	assert.equal(loadContextFiles(cwd, agent).length, 0);
});

test("context files: a read failure throws instead of silently dropping rules", (t) => {
	const { agent, project, cwd } = fixture(t);
	const file = join(project, "AGENTS.md");
	symlinkSync(file, file);
	assert.throws(() => loadContextFiles(cwd, agent), /ELOOP/);
});

test("context files: nested linked worktree shadows the main checkout", (t) => {
	const { agent, project } = fixture(t);
	const git = (...args: string[]) => execFileSync("git", ["-C", project, ...args], { stdio: "pipe" });
	git("init");
	git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial");
	writeFileSync(join(project, "AGENTS.md"), "main");
	const worktree = join(project, "worktrees", "task");
	git("worktree", "add", "--detach", worktree);
	writeFileSync(join(worktree, "AGENTS.md"), "task");
	assert.deepEqual(loadContextFiles(worktree, agent).map((file) => file.content), ["task"]);
});

function until(replica: ConversationReplica, predicate: () => boolean): Promise<void> {
	if (predicate()) return Promise.resolve();
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			stop();
			reject(new Error("context-file dev-server test timed out"));
		}, 15_000);
		const stop = replica.onChange(() => {
			if (!predicate()) return;
			clearTimeout(timer);
			stop();
			resolve();
		});
	});
}

async function chat(client: TauClient, replica: ConversationReplica, content: string, requestId: string): Promise<void> {
	const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId, content });
	await until(replica, () => replica.submissions.get(submission.id)?.status === "done" &&
		(replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined);
}

test("context files: a dev server injects rules, sends only deltas, follows cwd and keeps them on subagents", async (t) => {
	const { root, agent, project, cwd } = fixture(t);
	writeFileSync(join(agent, "AGENTS.md"), "GLOBAL_RULE_V1");
	const rule = join(project, "AGENTS.md");
	writeFileSync(rule, "PROJECT_RULE_V1");
	const reports: unknown[] = [];
	const host = await openHost({ cwd, contextFilesAgentDir: agent, skillsHome: root, devTokensPerSecond: 20_000, onReport: (report) => reports.push(report) });
	const server = await serve(host);
	const client = await TauClient.connect(server.url);
	try {
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const prompts = async (id = replica.id) => {
			const conversation = await host.harness.conversation(id as ConversationId, BACKGROUND_CONTEXT);
			const page = await conversation!.entries({ order: "ascending" }, 500, undefined, BACKGROUND_CONTEXT);
			return page.items.filter(SystemEntry.is);
		};
		const sections = async (id = replica.id) => (await prompts(id)).flatMap((entry) =>
			(entry.model ?? []).flatMap((message) => message.role === "system" && message.sections !== undefined ? [message.sections] : []));
		const rules = async (id = replica.id) => (await sections(id)).filter((section) => Object.hasOwn(section, "agents-md"));

		await chat(client, replica, "one", "context-1");
		assert.match((await rules())[0]!["agents-md"]!, /GLOBAL_RULE_V1[\s\S]*PROJECT_RULE_V1/);
		assert.ok(replica.ordered().filter((entry) => entry.kind === "pi.system").every((entry) => entry.model === undefined), "prompt contents are not sent to the phone");
		const initialCount = (await prompts()).length;
		await chat(client, replica, "two", "context-2");
		assert.equal((await prompts()).length, initialCount, "unchanged rules do not append another system entry");

		writeFileSync(rule, "PROJECT_RULE_V2");
		await chat(client, replica, "three", "context-3");
		assert.equal((await prompts()).length, initialCount + 1);
		assert.deepEqual(Object.keys((await sections()).at(-1)!), ["agents-md"], "only the rules section changed");
		assert.match((await rules()).at(-1)!["agents-md"]!, /PROJECT_RULE_V2/);

		// An unreadable replacement must not silently remove existing restrictions.
		rmSync(rule);
		symlinkSync(rule, rule);
		await chat(client, replica, "four", "context-4");
		assert.equal((await prompts()).length, initialCount + 1, "durable retains the last good section on a rendering error");
		assert.ok(reports.some((report) => JSON.stringify(report).includes("context-files")), "the failure is reported");
		rmSync(rule);
		writeFileSync(rule, "PROJECT_RULE_V2");

		// Only the free scripted dev model is used for this approved inheritance test.
		await chat(client, replica, "& context-child: say hi", "context-child");
		const started = replica.ordered().find((entry) => entry.kind === "pi.tool-result" &&
			(entry as unknown as { model?: { toolName?: string }[] }).model?.[0]?.toolName === "subagent") as unknown as { model: { details: { conversationId: number } }[] };
		assert.ok(started, "the scripted dev model started a child through the built-in tool");
		const child = new ConversationReplica(started.model[0]!.details.conversationId);
		await child.sync(client);
		await until(child, () => child.ordered().some((entry) => entry.kind === "pi.assistant") &&
			(child.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined);
		assert.match((await rules(child.id)).at(-1)!["agents-md"]!, /GLOBAL_RULE_V1[\s\S]*PROJECT_RULE_V2/);
		const childPrompt = JSON.stringify(await sections(child.id));
		assert.match(childPrompt, /You are the subagent/);
		assert.doesNotMatch(JSON.stringify((await prompts(child.id)).flatMap((entry) => entry.model ?? []).flatMap((message) => message.role === "system" ? message.toolsAdded ?? [] : [])), /"name":"subagent"/, "the child keeps context rules even though it has no subagent tool");

		const other = join(root, "other");
		mkdirSync(other);
		writeFileSync(join(other, "CLAUDE.md"), "OTHER_RULE");
		// cwd is host-controlled, intentionally not exposed by the client AgentPatch.
		const conversation = await host.harness.conversation(replica.id as ConversationId, BACKGROUND_CONTEXT);
		await conversation!.configure({ cwd: other }, BACKGROUND_CONTEXT);
		await chat(client, replica, "five", "context-5");
		const moved = (await rules()).at(-1)!["agents-md"]!;
		assert.match(moved, /GLOBAL_RULE_V1[\s\S]*OTHER_RULE/);
		assert.doesNotMatch(moved, /PROJECT_RULE/);
		rmSync(join(agent, "AGENTS.md"));
		rmSync(join(other, "CLAUDE.md"));
		await chat(client, replica, "six", "context-6");
		assert.equal((await rules()).at(-1)!["agents-md"], null, "deleting all rule files removes the section");
	} finally {
		await client.close();
		await server.close();
		await host.close();
	}
});

test("context files: global rules default to ~/.agents, ignoring Pi's global directory", (t) => {
	const { root, agent, cwd } = fixture(t);
	mkdirSync(join(root, ".agents"));
	writeFileSync(join(root, ".agents", "AGENTS.md"), "AGENTS_GLOBAL_RULE");
	writeFileSync(join(agent, "AGENTS.md"), "PI_GLOBAL_RULE_NOT_FOR_TAU");
	const module = new URL("../src/context-files.ts", import.meta.url).href;
	const script = `import { loadContextFiles } from ${JSON.stringify(module)}; console.log(JSON.stringify(loadContextFiles(${JSON.stringify(cwd)})));`;
	const output = execFileSync(process.execPath, ["--no-warnings", "--input-type=module", "-e", script], {
		encoding: "utf8",
		env: { ...process.env, HOME: root, USERPROFILE: root, PI_CODING_AGENT_DIR: agent },
	});
	assert.deepEqual(JSON.parse(output).map((file: { content: string }) => file.content), ["AGENTS_GLOBAL_RULE"]);
});

test("context files: linked worktree shadowing matches Pi's filename-specific rule", (t) => {
	const { agent, project } = fixture(t);
	const git = (...args: string[]) => execFileSync("git", ["-C", project, ...args], { stdio: "pipe" });
	git("init");
	git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial");
	writeFileSync(join(project, "CLAUDE.md"), "main fallback");
	const worktree = join(project, "worktrees", "task");
	git("worktree", "add", "--detach", worktree);
	writeFileSync(join(worktree, "AGENTS.md"), "task");
	assert.deepEqual(loadContextFiles(worktree, agent).map((file) => file.content), ["main fallback", "task"]);
});
