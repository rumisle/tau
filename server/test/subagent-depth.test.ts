import assert from "node:assert/strict";
import { tmpdir } from "node:os";
import { after, before, describe, test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { AgentDoc, type ConversationId } from "@earendil-works/pi-durable";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { type Host, MetaDoc, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";
import { EDITED_AWAY, Subagents } from "../src/subagent.ts";
import { hiddenIn, type VersionsState } from "../src/versions.ts";

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

function text(entry: Entry): string {
	const content = (entry.model as { content: string | { type: string; text?: string }[] }[] | undefined)?.[0]?.content;
	return typeof content === "string" ? content : (content ?? []).map((part) => part.text ?? "").join("");
}

function reports(replica: ConversationReplica): string[] {
	const hidden = (replica.docs["tau.versions"] as VersionsState | undefined)?.hidden ?? [];
	return replica
		.ordered()
		.filter((entry) => entry.kind === "pi.user" && !hiddenIn(hidden, entry.id))
		.map(text)
		.filter((each) => each.startsWith("<subagent "));
}

/** The conversation ID a subagent call's result names. */
function spawned(replica: ConversationReplica, nth = 0): number | undefined {
	const results = replica.ordered().filter((entry) => entry.kind === "pi.tool-result");
	return (results[nth]?.model as { details?: { conversationId?: number } }[] | undefined)?.[0]?.details?.conversationId;
}

describe("subagents: what they are told, how deep they go, and forks", () => {
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

	async function chat(title?: string): Promise<ConversationReplica> {
		const { dialog } = await client.request("conversation.create", title === undefined ? {} : { title });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		return replica;
	}
	async function subscribe(id: number): Promise<ConversationReplica> {
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		return replica;
	}
	const agentOf = async (id: number) => (await host.harness.conversation(id as ConversationId, BACKGROUND_CONTEXT))!.agent(BACKGROUND_CONTEXT);
	const tools = async (id: number) => (await agentOf(id)).tools.map((tool) => tool.name);
	const instructions = async (id: number) => (await host.harness.snapshot(AgentDoc, id as ConversationId, BACKGROUND_CONTEXT))?.instructions;

	test("a subagent is told whose it is and where its answers go; at the default depth of 2 its own subagents can't start more", async () => {
		const leader = await chat("Planning");
		await client.request("conversation.submit", { conversationId: leader.id, requestId: "d1", content: "& helper: & grand: look around" });
		await until(leader, () => spawned(leader) !== undefined);
		const child = await subscribe(spawned(leader)!);
		assert.match(
			(await instructions(child.id)) ?? "",
			new RegExp(`^You are the subagent "helper" of the chat "Planning" \\(tau://[0-9a-f]{8}/${leader.id}\\), which started you with the message below\\. At the end of each run, your last message goes back to that chat as your report\\.$`),
		);
		assert.ok((await tools(child.id)).includes("subagent"), "depth 1 of 2 may start subagents");
		await until(child, () => spawned(child) !== undefined);
		const grand = spawned(child)!;
		assert.ok(!(await tools(grand)).includes("subagent"), "depth 2 of 2 may not");
		await until(leader, () => reports(leader).length >= 1, 20_000);
	});

	test("the depth is a setting: at 1, subagents start none", async () => {
		const settings = await client.request("settings.configure", { subagentDepth: 1 });
		assert.equal(settings.subagentDepth, 1);
		try {
			const leader = await chat();
			await client.request("conversation.submit", { conversationId: leader.id, requestId: "s1", content: "& solo: hi" });
			await until(leader, () => spawned(leader) !== undefined);
			assert.ok(!(await tools(spawned(leader)!)).includes("subagent"));
			await assert.rejects(client.request("settings.configure", { subagentDepth: 9 }), /1 to 5/);
		} finally {
			await client.request("settings.configure", { subagentDepth: 2 });
		}
	});

	test("a report whose work was given in a part the user edited away says so", async () => {
		const leader = await chat();
		await client.request("conversation.submit", { conversationId: leader.id, requestId: "a1", content: "& slow: ~2 take your time" });
		await until(leader, () => spawned(leader) !== undefined);
		const spawn = leader.ordered().find((entry) => entry.kind === "pi.user")!;
		await until(leader, () => idle(leader));
		await client.request("conversation.submit", { conversationId: leader.id, requestId: "a2", content: "never mind", edit: spawn.id });
		await until(leader, () => reports(leader).length === 1, 20_000);
		assert.ok(reports(leader)[0]!.includes(EDITED_AWAY), reports(leader)[0]);
	});

	test("a fork copies the subagents as they were at the fork point; each copy reports to the fork", async () => {
		const leader = await chat("Original");
		await client.request("conversation.submit", { conversationId: leader.id, requestId: "f1", content: "& helper: first task" });
		await until(leader, () => reports(leader).length === 1 && idle(leader), 20_000);
		const original = spawned(leader)!;
		const at = leader.ordered().at(-1)!.id;
		const { dialog } = await client.request("conversation.fork", { conversationId: leader.id, at, title: "Forked" });
		const fork = await subscribe(dialog.conversation.id);
		const agents = (await host.harness.snapshot(Subagents, fork.id as ConversationId, BACKGROUND_CONTEXT))?.agents ?? {};
		const copy = agents.helper?.conversationId;
		assert.ok(copy !== undefined && copy !== original, "a copy of its own");
		assert.equal((await host.harness.snapshot(MetaDoc, copy as ConversationId, BACKGROUND_CONTEXT))?.title, "helper: first task");
		assert.match((await instructions(copy)) ?? "", /of the chat "Forked"/);
		assert.match((await instructions(fork.id)) ?? "", /^This chat is a fork of the chat "Original" \(tau:\/\/[0-9a-f]{8}\/\d+\)/);
		const copied = await subscribe(copy);
		assert.ok(copied.ordered().some((entry) => entry.kind === "pi.assistant" && text(entry).startsWith("You said: first task")), "with its history");
		// Work given to the copy reports to the fork, not the original.
		await client.request("conversation.submit", { conversationId: fork.id, requestId: "f2", content: '!tool subagent {"action":"send","name":"helper","message":"second task"}' });
		await until(fork, () => reports(fork).some((each) => each.includes("second task")), 20_000);
		assert.equal(reports(leader).length, 1);
	});

	test("a fork of a subagent's chat is a chat: no longer a subagent, and it may start its own", async () => {
		const leader = await chat("Boss");
		await client.request("conversation.submit", { conversationId: leader.id, requestId: "g1", content: "& worker: do it" });
		await until(leader, () => reports(leader).length === 1, 20_000);
		const worker = await subscribe(spawned(leader)!);
		await until(worker, () => idle(worker));
		const { dialog } = await client.request("conversation.fork", { conversationId: worker.id, at: worker.ordered().at(-1)!.id });
		assert.equal(dialog.conversation.owner, undefined);
		assert.ok((await tools(dialog.conversation.id)).includes("subagent"));
		assert.doesNotMatch((await instructions(dialog.conversation.id)) ?? "", /You are the subagent/);
	});
});
