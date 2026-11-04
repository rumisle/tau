import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { CommandFacts, signalOf } from "../src/commands.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";

const MAIN = join(import.meta.dirname, "..", "src", "main.ts");

function until(replica: ConversationReplica, predicate: () => boolean, timeoutMs = 20_000): Promise<void> {
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

const results = (replica: ConversationReplica) => replica.ordered().filter((entry) => entry.kind === "pi.tool-result");
const text = (entry: Entry | undefined) => ((entry?.model as { content: { type: string; text?: string }[] }[] | undefined)?.[0]?.content ?? []).map((part) => part.text ?? "").join("\n");
const idle = (replica: ConversationReplica) => (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined;

async function chat(client: TauClient): Promise<ConversationReplica> {
	const { dialog } = await client.request("conversation.create", { agent: { model: { provider: "dev", modelId: "echo" } } });
	const replica = new ConversationReplica(dialog.conversation.id);
	await replica.sync(client);
	return replica;
}

/** Sends `content` and waits for the run to end with one more tool result. */
async function run(client: TauClient, replica: ConversationReplica, content: string): Promise<Entry> {
	const before = results(replica).length;
	await client.request("conversation.submit", { conversationId: replica.id, requestId: `${content}-${Math.random()}`, content });
	await until(replica, () => results(replica).length > before && idle(replica));
	return results(replica).at(-1)!;
}

describe("commands: how they ended", () => {
	let host: Host;
	let server: Server;
	let client: TauClient;
	before(async () => {
		host = await openHost({ devTokensPerSecond: 4_000, cwd: tmpdir() });
		server = await serve(host);
		client = await TauClient.connect(server.url);
	});
	after(async () => {
		await client.close();
		await server.close();
		await host.close();
	});

	test("a command killed by a signal is reported as such, with the signal in the structured output", async () => {
		const replica = await chat(client);
		const killed = await run(client, replica, "$ kill -9 $$");
		assert.match(text(killed), /Killed by SIGKILL \(exit 137\)\./);
		assert.doesNotMatch(text(killed), /exited with code/);
		const terminated = await run(client, replica, "$ kill -TERM $$");
		assert.match(text(terminated), /Killed by SIGTERM \(exit 143\)\./);
		const plain = await run(client, replica, "$ exit 3");
		assert.match(text(plain), /Command exited with code 3/);
		// A script gets the signal in the structured output.
		const scripted = await run(client, replica, "!code const r = await tools.bash({ command: 'kill -9 $$' }); return JSON.stringify(r);");
		assert.match(text(scripted), /"exitCode":137,"signal":"SIGKILL"/);
		assert.equal(signalOf(137), "SIGKILL");
		assert.equal(signalOf(1), undefined);
		assert.equal(signalOf(250), undefined);
	});

	test("the OOM killer acting in the server's cgroup while a command ran is said, from memory.events", () => {
		const dir = mkdtempSync(join(tmpdir(), "tau-cgroup-"));
		try {
			writeFileSync(join(dir, "cgroup"), "0::/user.slice/tau-server.service\n");
			const unit = join(dir, "root", "user.slice", "tau-server.service");
			mkdirSync(unit, { recursive: true });
			const events = (kills: number) => writeFileSync(join(unit, "memory.events"), `low 0\nhigh 0\nmax 3\noom 1\noom_kill ${kills}\noom_group_kill 0\n`);
			events(2);
			const facts = new CommandFacts({ procCgroup: join(dir, "cgroup"), cgroupRoot: join(dir, "root") });
			assert.equal(facts.unit, "tau-server.service");
			assert.equal(facts.oomKills(), 2);
			const api = { conversationId: 7, callId: "call-1" } as never;
			const result = { isError: true, structuredOutput: { output: "", truncated: false, exitCode: 137 }, diagnostics: [{ severity: "error", code: "exit_code", message: "Command exited with code 137" }] } as const;
			// No kill while it ran: the signal only.
			facts.prepare({ command: "", cwd: "/", env: {}, inheritEnv: true }, api, {} as never);
			let explained = facts.explain(7, "call-1", result);
			assert.deepEqual(explained.diagnostics!.map((diagnostic) => diagnostic.message), ["Killed by SIGKILL (exit 137)."]);
			// One while it ran.
			facts.prepare({ command: "", cwd: "/", env: {}, inheritEnv: true }, api, {} as never);
			events(3);
			explained = facts.explain(7, "call-1", result);
			assert.deepEqual(explained.diagnostics!.map((diagnostic) => diagnostic.message), ["Killed by SIGKILL (exit 137).", "The kernel's OOM killer acted in tau-server.service while it ran."]);
			assert.deepEqual(explained.structuredOutput, { output: "", truncated: false, exitCode: 137, signal: "SIGKILL", oomKill: true });
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});

describe("commands: interrupted by a restart", () => {
	const dir = mkdtempSync(join(tmpdir(), "tau-commands-"));
	after(() => rmSync(dir, { recursive: true, force: true }));

	/** A server on `database` whose machine's boot ID is the file `boot`. */
	function launch(database: string, port: number, boot: string): ChildProcess {
		return spawn(process.execPath, ["--no-warnings", MAIN, "--db", database, "--port", String(port), "--dev-tps", "2000", "--cwd", dir], {
			stdio: ["ignore", "pipe", "inherit"],
			env: { ...process.env, TAU_BOOT_ID_PATH: boot },
		});
	}
	const ready = (child: ChildProcess) => new Promise<void>((resolve) => child.stdout!.on("data", (data) => data.toString().includes("listening") && resolve()));

	for (const [name, rebooted] of [["a reboot (the boot ID changed)", true], ["a restart of the server alone", false]] as const) {
		test(`a command cut off by ${name} says so`, async () => {
			const database = join(dir, `${rebooted ? "reboot" : "restart"}.db`);
			const boot = join(dir, `${rebooted ? "reboot" : "restart"}-boot`);
			const port = 20_000 + Math.floor(Math.random() * 20_000);
			writeFileSync(boot, "11111111-1111-1111-1111-111111111111\n");
			let child = launch(database, port, boot);
			await ready(child);
			let client = await TauClient.connect(`ws://127.0.0.1:${port}`);
			let replica = await chat(client);
			await client.request("conversation.submit", { conversationId: replica.id, requestId: "long", content: "$ sleep 30" });
			await until(replica, () => ((replica.docs["pi.live"] as { tools?: { status: string }[] } | undefined)?.tools ?? []).some((slot) => slot.status === "running"));
			child.kill("SIGKILL");
			await client.closed;
			if (rebooted) writeFileSync(boot, "22222222-2222-2222-2222-222222222222\n");
			child = launch(database, port, boot);
			await ready(child);
			client = await TauClient.connect(`ws://127.0.0.1:${port}`);
			const id = replica.id;
			replica = new ConversationReplica(id);
			await replica.sync(client);
			await until(replica, () => results(replica).length > 0 && idle(replica));
			const said = text(results(replica)[0]);
			assert.match(said, /interrupted/);
			assert.match(said, rebooted ? /The machine rebooted while this command ran \(boot ID changed\)\./ : /The tau server restarted while this command ran\./);
			await client.close();
			child.kill("SIGTERM");
			await new Promise((resolve) => child.once("exit", resolve));
		});
	}
});

// A real OOM kill, in a transient scope with a small memory limit, where the user's systemd manages cgroups with the
// memory controller delegated; skipped elsewhere.
const scopes = process.platform === "linux" && spawnSync("systemd-run", ["--user", "--scope", "--quiet", "-p", "MemoryMax=64M", "true"]).status === 0;
describe("commands: the OOM killer, for real", { skip: scopes ? false : "no systemd user scopes with a memory limit here" }, () => {
	test("a command over its server's memory limit: killed by SIGKILL, and the OOM killer named", async () => {
		const dir = mkdtempSync(join(tmpdir(), "tau-oom-"));
		const unit = `tau-test-oom-${process.pid}`;
		const port = 20_000 + Math.floor(Math.random() * 20_000);
		const child = spawn(
			"systemd-run",
			["--user", "--scope", "--quiet", `--unit=${unit}`, "-p", "MemoryMax=400M", "-p", "MemorySwapMax=0", "-p", "OOMPolicy=continue", "--", process.execPath, "--no-warnings", MAIN, "--memory", "--port", String(port), "--dev-tps", "2000", "--cwd", dir],
			{ stdio: ["ignore", "pipe", "inherit"] },
		);
		try {
			await new Promise<void>((resolve) => child.stdout!.on("data", (data) => data.toString().includes("listening") && resolve()));
			const client = await TauClient.connect(`ws://127.0.0.1:${port}`);
			const replica = await chat(client);
			const result = await run(client, replica, "$ python3 -c 'a = bytearray(800 << 20)'");
			assert.match(text(result), /Killed by SIGKILL \(exit 137\)\./);
			assert.match(text(result), new RegExp(`The kernel's OOM killer acted in ${unit}\\.scope while it ran\\.`));
			await client.close();
		} finally {
			spawnSync("systemctl", ["--user", "stop", `${unit}.scope`]);
			spawnSync("systemctl", ["--user", "reset-failed", `${unit}.scope`]);
			rmSync(dir, { recursive: true, force: true });
		}
	});
});
