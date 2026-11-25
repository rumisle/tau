// Providers from outside tau (src/external-providers.ts, docs/deploy.md): a provider file loaded with its models, chat
// and its keys' usage, with and without a limit; files that cannot be used skipped with the server running; a usage
// report checked.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { Accounts, type AccountsState } from "../src/accounts.ts";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { loadProviderFile } from "../src/external-providers.ts";
import { nextMonth } from "./fixtures/gateway-provider.ts";
import { type Host, openHost } from "../src/host.ts";
import { PlanUsage, usageReport } from "../src/plan-usage.ts";
import { type Server, serve } from "../src/server.ts";

const FIXTURE = join(import.meta.dirname, "fixtures", "gateway-provider.ts");
const MAIN = join(import.meta.dirname, "..", "src", "main.ts");

async function eventually<T>(read: () => T | undefined | Promise<T | undefined>, what: string, timeoutMs = 10_000): Promise<T> {
	const end = Date.now() + timeoutMs;
	for (;;) {
		const value = await read();
		if (value !== undefined) return value;
		if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
}

function assistantText(entry: Entry | undefined): string {
	const message = (entry as { model?: { content: { type: string; text?: string }[] }[] } | undefined)?.model?.[0];
	return message?.content.find((part) => part.type === "text")?.text ?? "";
}

describe("external providers: a provider file", () => {
	let host: Host;
	let server: Server;
	let client: TauClient;
	before(async () => {
		host = await openHost({ providers: [FIXTURE], modelCatalog: false, devTokensPerSecond: 2_000, cwd: tmpdir(), accounts: new Accounts(), log: () => {} });
		server = await serve(host);
		client = await TauClient.connect(server.url);
	});
	after(async () => {
		client.close();
		await server.close();
		await host.close();
	});

	test("its provider is offered for a key; the key brings its models, and chat on them goes with the key", async () => {
		assert.deepEqual(host.providerFiles, { loaded: [{ id: "fixture-gateway", file: FIXTURE }], skipped: [] });
		const state = (await client.request("accounts.subscribe", {})) as AccountsState;
		assert.deepEqual(state.providers.find((each) => each.id === "fixture-gateway"), { id: "fixture-gateway", name: "Fixture Gateway", apiKey: { name: "Fixture Gateway key" } });
		assert.equal(host.models.getModel("fixture-gateway", "gateway-chat"), undefined, "no models before a key");

		// A key added: the catalog is asked again with it, at once.
		await host.accounts.accounts.add("fixture-gateway", { type: "api_key", key: "gw-123" }, {});
		await eventually(() => host.models.getModel("fixture-gateway", "gateway-chat"), "the gateway's models");
		const listed = (await client.request("models.list", {})) as { models: { provider: string; id: string }[] };
		assert.ok(listed.models.some((model) => model.provider === "fixture-gateway" && model.id === "gateway-chat"), "listed to clients");

		const { dialog } = (await client.request("conversation.create", {})) as { dialog: { conversation: { id: number } } };
		const id = dialog.conversation.id;
		await client.request("conversation.configure", { conversationId: id, agent: { model: { provider: "fixture-gateway", modelId: "gateway-chat" } } });
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		await client.request("conversation.submit", { conversationId: id, requestId: "g1", content: "hello" });
		const answer = await eventually(() => replica.ordered().find((entry) => entry.kind === "pi.assistant" && assistantText(entry) !== ""), "the answer");
		assert.equal(assistantText(answer), "Gateway heard hello with gw-123");
	});

	test("its key's usage: a window with a limit, and the month's spend without one", async () => {
		const account = host.accounts.accounts.all().find((each) => each.provider === "fixture-gateway")!;
		await client.request("accounts.refresh", { id: account.id });
		const state = await eventually(async () => {
			const each = (await client.request("accounts.subscribe", {})) as AccountsState;
			return each.accounts.find((one) => one.id === account.id)?.usage === undefined ? undefined : each;
		}, "the usage");
		assert.deepEqual(state.accounts.find((one) => one.id === account.id)!.usage!.windows, [
			{ id: "budget", label: "Budget", title: "Monthly Budget", usedPercent: 25, amount: "$25.00 of $100.00 spent", resetsAt: nextMonth(), seconds: 2_592_000 },
			{ id: "month", label: "Month", title: "This Month", amount: "$2,383.76 spent", resetsAt: nextMonth(), seconds: 2_592_000 },
		]);
	});
});

describe("external providers: files that cannot be used", () => {
	test("one that throws, one with the wrong export, one with a built-in's id, one loaded twice: each skipped, logged, and the server runs", async () => {
		const dir = mkdtempSync(join(tmpdir(), "tau-providers-"));
		const throws = join(dir, "throws.ts");
		writeFileSync(throws, `throw new Error("boom");\n`);
		const wrong = join(dir, "wrong.ts");
		writeFileSync(wrong, "export const provider = 42;\n");
		const taken = join(dir, "taken.ts");
		writeFileSync(taken, `export const provider = { id: "anthropic", name: "Not Anthropic", auth: { apiKey: { name: "k", resolve: async () => undefined } }, getModels: () => [] };\n`);
		const missing = join(dir, "missing.ts");
		const lines: string[] = [];
		const host = await openHost({ providers: [throws, wrong, taken, missing, FIXTURE, FIXTURE], modelCatalog: false, devTokensPerSecond: 2_000, cwd: tmpdir(), log: (line) => lines.push(line) });
		try {
			assert.deepEqual(host.providerFiles.loaded, [{ id: "fixture-gateway", file: FIXTURE }]);
			const reasons = Object.fromEntries(host.providerFiles.skipped.map((each) => [each.file, each.reason]));
			assert.match(reasons[throws]!, /did not load: boom/);
			assert.match(reasons[wrong]!, /exports no provider/);
			assert.equal(reasons[taken], "provider anthropic is already registered");
			assert.match(reasons[missing]!, /did not load/);
			assert.equal(reasons[FIXTURE], "provider fixture-gateway is already registered");
			assert.equal(lines.filter((line) => line.includes("skipped")).length, 5, lines.join("\n"));
			assert.equal(host.models.getProvider("anthropic")?.name, "Anthropic", "the built-in stays");
			// The server still works: the dev model answers.
			assert.ok(host.models.getModel("dev", "echo"));
		} finally {
			await host.close();
		}
	});

	test("--check-providers says what each file gave, and exits 3 when one is skipped", () => {
		const dir = mkdtempSync(join(tmpdir(), "tau-providers-"));
		const wrong = join(dir, "wrong.ts");
		writeFileSync(wrong, "export default {};\n");
		const run = spawnSync(process.execPath, ["--no-warnings", MAIN, "--memory", "--provider", FIXTURE, "--provider", wrong, "--check-providers"], { encoding: "utf8" });
		assert.equal(run.status, 3, run.stderr);
		assert.match(run.stdout, /^fixture-gateway from .*gateway-provider\.ts, with key usage$/m);
		assert.match(run.stdout, /^skipped .*wrong\.ts: it exports no provider/m);
	});

	test("the same file is a pi extension: its default export registers the provider with pi's API", async () => {
		const module = (await import(FIXTURE)) as { default: (pi: { registerProvider(provider: unknown): void }) => void };
		const registered: unknown[] = [];
		module.default({ registerProvider: (provider) => registered.push(provider) });
		assert.equal((registered[0] as { id: string }).id, "fixture-gateway");
		assert.equal((await loadProviderFile(FIXTURE)).provider, registered[0], "the module tau loaded, once");
	});
});

describe("external providers: a usage report", () => {
	test("checked: fields it knows, a title from the label, and errors naming what is wrong", () => {
		assert.deepEqual(usageReport({ windows: [{ id: "m", label: "Month", amount: "$3 spent", extra: true }] }), { windows: [{ id: "m", label: "Month", title: "Month", amount: "$3 spent" }] });
		assert.throws(() => usageReport(null), /malformed usage: not an object/);
		assert.throws(() => usageReport({}), /no windows list/);
		assert.throws(() => usageReport({ windows: [{ id: "m", label: "Month" }] }), /window 1 has neither usedPercent nor amount/);
		assert.throws(() => usageReport({ windows: [{ id: "m", label: "Month", usedPercent: Number.NaN }] }), /usedPercent is not a number/);
		assert.throws(() => usageReport({ windows: [{ label: "Month", usedPercent: 1 }] }), /window 1 has no id/);
	});

	test("a malformed report, or none in time, is the account's usage error", async () => {
		const accounts = new Accounts();
		const { usage: external } = await loadProviderFile(FIXTURE);
		const keyFetcher = async (key: string, fetchImpl: typeof fetch, signal: AbortSignal) => (await external.apiKey!(key, { fetch: fetchImpl, signal })) as never;
		const usage = new PlanUsage({ accounts, models: {} as never, minAskMs: 0, keyTimeoutMs: 100, keyFetchers: { "fixture-gateway": keyFetcher }, onChange: () => {} });
		const bad = await accounts.add("fixture-gateway", { type: "api_key", key: "bad-usage" }, {});
		await usage.refresh(bad.id);
		assert.equal(usage.of(bad.id)?.error, "malformed usage: window 1 has neither usedPercent nor amount");
		const slow = await accounts.add("fixture-gateway", { type: "api_key", key: "slow-usage" }, {});
		await usage.refresh(slow.id);
		assert.equal(usage.of(slow.id)?.error, "its usage did not answer in 0.1 s");
		assert.deepEqual(usage.of(slow.id)?.windows, []);
	});
});
