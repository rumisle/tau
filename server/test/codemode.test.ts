import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, TauClient } from "../src/client.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC", "base64");

type Entry = { id: number; kind: string; data?: Record<string, unknown>; model?: { role: string; toolName?: string; content: { type: string; text?: string }[]; details?: { calls: { name: string; status: string }[] } }[] };

describe("code mode", () => {
	let host: Host;
	let server: Server;
	let cwd: string;
	before(async () => {
		cwd = mkdtempSync(join(tmpdir(), "tau-codemode-cwd-"));
		host = await openHost({ devTokensPerSecond: 2_000, cwd });
		server = await serve(host);
	});
	after(async () => {
		await server.close();
		await host.close();
		rmSync(cwd, { recursive: true, force: true });
	});

	const until = (replica: ConversationReplica, predicate: () => boolean) =>
		new Promise<void>((resolve, reject) => {
			if (predicate()) return resolve();
			const timer = setTimeout(() => reject(new Error("timed out")), 15_000);
			const stop = replica.onChange(() => {
				if (!predicate()) return;
				clearTimeout(timer);
				stop();
				resolve();
			});
		});

	test("a script's calls run as nested calls, and what the user sees of them comes as display entries", async () => {
		writeFileSync(join(cwd, "chart.png"), PNG);
		const client = await TauClient.connect(server.url);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const script = [
			'const run = await tools.bash({ command: "echo hi" });',
			'await tools.send_file({ paths: ["chart.png"] });',
			'await tools.subagent({ action: "spawn", name: "helper", message: "say hi" });',
			'await tools.subagent({ action: "spawn", name: "copy", message: "go on", fork: true });',
			"return run.output.trim();",
		].join("\n");
		await client.request("conversation.submit", { conversationId: replica.id, requestId: "c-1", content: `!code ${script}` });
		const entries = () => replica.ordered() as unknown as Entry[];
		const result = () => entries().find((entry) => entry.kind === "pi.tool-result" && entry.model?.[0]?.toolName === "codemode");
		await until(replica, () => result() !== undefined);
		const kinds = entries().map((entry) => entry.kind);
		// Between the call and its result, where the script made them.
		const call = kinds.indexOf("pi.assistant");
		const files = kinds.indexOf("tau.files");
		const subagent = kinds.indexOf("tau.subagent");
		assert.equal(kinds.filter((kind) => kind === "tau.subagent").length, 2);
		const done = entries().indexOf(result()!);
		assert.ok(call < files && files < subagent && subagent < done, kinds.join(", "));
		const sent = entries()[files]!.data as { callId: string; files: { name: string; mimeType: string }[] };
		assert.match(sent.callId, /\//, "a nested call's ID");
		assert.deepEqual(sent.files.map((file) => [file.name, file.mimeType]), [["chart.png", "image/png"]]);
		const started = entries()[subagent]!.data as { action: string; name: string; message: string; conversationId: number };
		assert.equal(started.action, "spawn");
		assert.equal(started.name, "helper");
		assert.equal(started.message, "say hi");
		assert.equal(typeof started.conversationId, "number");
		const message = result()!.model![0]!;
		assert.deepEqual(message.details!.calls.map((each) => [each.name, each.status]), [["bash", "ok"], ["send_file", "ok"], ["subagent", "ok"], ["subagent", "ok"]]);
		const text = message.content.map((part) => part.text ?? "").join("");
		assert.match(text, /^Script completed\n/);
		assert.match(text, /hi$/);
		// A fork from a script starts from the conversation before the script's call.
		const forked = entries().filter((entry) => entry.kind === "tau.subagent")[1]!.data as { conversationId: number; fork?: true };
		assert.equal(forked.fork, true);
		const copy = new ConversationReplica(forked.conversationId);
		await copy.sync(client);
		await until(copy, () => (copy.ordered() as unknown as Entry[]).some((entry) => entry.kind === "pi.user"));
		const first = (copy.ordered() as unknown as Entry[]).find((entry) => entry.kind === "pi.user")!;
		assert.match(JSON.stringify(first.model), /!code/);
		await client.close();
	});
});
