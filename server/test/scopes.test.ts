import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { after, before, describe, test } from "node:test";
import { ConversationReplica, type Entry, TauClient } from "../src/client.ts";
import { type Host, openHost } from "../src/host.ts";
import { CommandScopes, escapeUnitPart, formatBytes, scopeUnit } from "../src/scopes.ts";
import { type Server, serve } from "../src/server.ts";

function until(predicate: () => boolean | Promise<boolean>, timeoutMs = 20_000): Promise<void> {
	const end = Date.now() + timeoutMs;
	return new Promise((resolve, reject) => {
		const poll = async () => {
			if (await predicate()) return resolve();
			if (Date.now() > end) return reject(new Error("timed out"));
			setTimeout(poll, 50);
		};
		void poll();
	});
}

const results = (replica: ConversationReplica) => replica.ordered().filter((entry) => entry.kind === "pi.tool-result");
const text = (entry: Entry | undefined) => ((entry?.model as { content: { type: string; text?: string }[] }[] | undefined)?.[0]?.content ?? []).map((part) => part.text ?? "").join("\n");
const idle = (replica: ConversationReplica) => (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined;
const running = (replica: ConversationReplica) => ((replica.docs["pi.live"] as { tools?: { status: string }[] } | undefined)?.tools ?? []).some((slot) => slot.status === "running");

async function chat(client: TauClient): Promise<ConversationReplica> {
	const { dialog } = await client.request("conversation.create", { agent: { model: { provider: "dev", modelId: "echo" } } });
	const replica = new ConversationReplica(dialog.conversation.id);
	await replica.sync(client);
	return replica;
}

async function submit(client: TauClient, replica: ConversationReplica, content: string): Promise<number> {
	const count = results(replica).length;
	await client.request("conversation.submit", { conversationId: replica.id, requestId: `${content}-${Math.random()}`, content });
	return count;
}

/** Sends `content` and waits for the run to end with one more tool result. */
async function run(client: TauClient, replica: ConversationReplica, content: string): Promise<Entry> {
	const count = await submit(client, replica, content);
	await until(() => results(replica).length > count && idle(replica));
	return results(replica).at(-1)!;
}

const systemctl = (...args: string[]) => spawnSync("systemctl", ["--user", ...args], { encoding: "utf8" });
const property = (unit: string, name: string) => systemctl("show", unit, "-p", name, "--value").stdout.trim();
/** The units, any type, whose names start with `prefix`. */
const units = (prefix: string) =>
	systemctl("list-units", "--all", "--plain", "--no-legend", `${prefix}*`)
		.stdout.split("\n")
		.map((line) => line.trim().split(/\s+/)[0]!)
		.filter((unit) => unit !== "" && unit.startsWith(prefix));
const alive = (pid: number) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

test("unit names: a call ID's characters past letters, digits, _ and - escaped, a long one hashed", () => {
	assert.equal(escapeUnitPart("toolu_01AbC-x"), "toolu_01AbC-x");
	assert.equal(escapeUnitPart("tool:1/c2"), "tool\\x3a1\\x2fc2");
	assert.equal(escapeUnitPart("é"), "\\xc3\\xa9");
	assert.equal(scopeUnit("tau-cmd-", 12, "toolu_1/c3"), "tau-cmd-12-toolu_1\\x2fc3.scope");
	assert.match(scopeUnit("tau-cmd-", 12, "x/".repeat(100)), /^tau-cmd-12-[0-9a-f]{32}\.scope$/);
	assert.equal(formatBytes(300 << 20), "300 MiB");
	assert.equal(formatBytes(2.5 * 2 ** 30), "2.5 GiB");
	assert.equal(formatBytes(26 * 2 ** 30), "26 GiB");
});

// The rest needs the user's systemd with scopes and the memory controller delegated; skipped elsewhere.
const scopes = process.platform === "linux" && spawnSync("systemd-run", ["--user", "--scope", "--quiet", "-p", "MemoryMax=64M", "true"]).status === 0;
describe("commands in scopes", { skip: scopes ? false : "no systemd user scopes with a memory limit here" }, () => {
	// A slice of this test run's own, under tau.slice like tau-cmd.slice: tau-t<pid>.slice/tau-t<pid>-cmd.slice.
	const parent = `tau-t${process.pid}.slice`;
	const slice = `tau-t${process.pid}-cmd.slice`;
	const prefix = `tau-t${process.pid}-cmd-`;
	const owner = `tau-t${process.pid}-owner.service`;
	let host: Host;
	let server: Server;
	let client: TauClient;
	before(async () => {
		systemctl("set-property", "--runtime", slice, "MemoryMax=300M", "MemorySwapMax=0");
		// The scopes' BindsTo=: a service of the test's, standing for the server's, restarted as tau-server.service is.
		spawnSync("systemd-run", ["--user", "--quiet", `--unit=${owner}`, "-p", "Restart=always", "-p", "RestartSec=1", "--", "sleep", "600"]);
		host = await openHost({ devTokensPerSecond: 4_000, cwd: tmpdir(), commandScopes: { slice, boundTo: owner } });
		server = await serve(host);
		client = await TauClient.connect(server.url);
	});
	after(async () => {
		await client.close();
		await server.close();
		await host.close();
		// Only this run's units.
		for (const unit of [...units(prefix), ...units(`tau-t${process.pid}`)]) {
			systemctl("stop", unit);
			systemctl("reset-failed", unit);
		}
		systemctl("stop", parent);
		systemctl("revert", slice);
	});

	test("a command runs in its own scope in the slice, its OOM score raised, the arguments as given", async () => {
		const replica = await chat(client);
		const result = await run(client, replica, `$ cat /proc/self/cgroup; cat /proc/self/oom_score_adj; echo "[$TAU_CMD_UNIT]" 'a  "b'`);
		const [cgroup, score, rest] = text(result).split("\n");
		assert.match(cgroup!, new RegExp(`/${parent}/${slice}/${prefix}${replica.id}-[^/]+\\.scope$`));
		assert.equal(score, "500");
		assert.equal(rest, `[] a  "b`);
		// A script's nested call: its ID has a '/', escaped.
		const nested = await run(client, replica, "!code const r = await tools.bash({ command: 'cat /proc/self/cgroup' }); return r.output;");
		assert.match(text(nested), new RegExp(`${prefix}${replica.id}-[^/]*\\\\x2f[^/]*\\.scope`));
		// The exit code is the command's.
		assert.match(text(await run(client, replica, "$ exit 3")), /Command exited with code 3/);
	});

	test("a background process outlives its call, in the call's scope", async () => {
		const replica = await chat(client);
		const result = await run(client, replica, "$ sleep 300 >/dev/null 2>&1 & echo $!");
		const pid = Number(text(result).trim());
		assert.ok(alive(pid));
		const [unit] = units(`${prefix}${replica.id}-`);
		assert.ok(unit !== undefined);
		assert.equal(property(unit, "ActiveState"), "active");
		systemctl("stop", unit);
		await until(() => !alive(pid));
	});

	test("stop and timeout stop the call's scope, processes that left its process group too", async () => {
		const replica = await chat(client);
		// setsid: out of the process group the tool kills.
		await submit(client, replica, "$ setsid sleep 301 >/dev/null 2>&1 < /dev/null & sleep 300");
		await until(() => running(replica) && units(`${prefix}${replica.id}-`).length > 0);
		const [unit] = units(`${prefix}${replica.id}-`);
		await client.request("conversation.abort", { conversationId: replica.id });
		await until(() => idle(replica));
		await until(() => property(unit!, "ActiveState") !== "active");
		assert.equal(spawnSync("pgrep", ["-f", "^sleep 301$"]).status, 1);

		const timed = await run(client, replica, `!tool bash {"command":"setsid sleep 302 >/dev/null 2>&1 < /dev/null & sleep 300","timeout":1}`);
		assert.match(text(timed), /timed out/);
		await until(() => units(`${prefix}${replica.id}-`).every((name) => property(name, "ActiveState") !== "active"));
		assert.equal(spawnSync("pgrep", ["-f", "^sleep 302$"]).status, 1);
	});

	test("killed by the OOM killer at the slice's limit: the facts, and the failed scope reset", async () => {
		const replica = await chat(client);
		const result = await run(client, replica, "$ python3 -c 'a = bytearray(600 << 20)'");
		const said = text(result);
		assert.match(said, /Killed by the out-of-memory killer \(exit 137\)\./);
		assert.match(said, new RegExp(`Memory limit reached: 300 MiB \\(${slice}\\)\\. This command's peak: \\d+ MiB\\.`));
		assert.doesNotMatch(said, /SIGKILL|exited with code/);
		const scripted = await run(client, replica, "!code const r = await tools.bash({ command: \"python3 -c 'a = bytearray(600 << 20)'\" }); const { output, ...rest } = r; return JSON.stringify(rest);");
		const value = JSON.parse(/\{.*\}/.exec(text(scripted))![0]) as Record<string, unknown>;
		assert.equal(value.oomKilled, true);
		assert.equal(value.memoryLimit, 300 << 20);
		assert.equal(value.memoryLimitUnit, slice);
		assert.equal(typeof value.memoryPeak, "number");
		// Read, then reset: none left failed.
		assert.deepEqual(units(`${prefix}${replica.id}-`), []);
	});

	test("the scopes are bound to the server's unit: its crash (and restart) stops them, as its stop does", async () => {
		const replica = await chat(client);
		const background = async () => Number(text(await run(client, replica, "$ sleep 303 >/dev/null 2>&1 & echo $!")).trim());
		let pid = await background();
		const [unit] = units(`${prefix}${replica.id}-`);
		assert.equal(property(unit!, "BindsTo"), owner);
		assert.match(property(unit!, "After"), new RegExp(owner.replaceAll(".", "\\.")));
		// A crash: the main process killed, systemd restarting the service.
		const restarts = Number(property(owner, "NRestarts"));
		systemctl("kill", "-s", "KILL", owner);
		await until(() => !alive(pid));
		await until(() => Number(property(owner, "NRestarts")) > restarts && property(owner, "ActiveState") === "active");
		assert.equal(property(unit!, "ActiveState"), "inactive");
		// A stop.
		pid = await background();
		systemctl("stop", owner);
		await until(() => !alive(pid));
	});

	test("systemd-run failing: the command fails, saying so, and does not run outside a scope", async () => {
		const masked = `tau-t${process.pid}m-cmd.slice`;
		systemctl("mask", "--runtime", masked);
		const other = await openHost({ devTokensPerSecond: 4_000, cwd: tmpdir(), commandScopes: { slice: masked } });
		const otherServer = await serve(other);
		const otherClient = await TauClient.connect(otherServer.url);
		try {
			const replica = await chat(otherClient);
			const result = await run(otherClient, replica, "$ echo ran");
			assert.match(text(result), /The command did not start: systemd-run could not start its scope tau-t\d+m-cmd-\d+-.+\.scope\./);
			assert.match(text(result), /masked/);
			assert.doesNotMatch(text(result), /^ran$/m);
			assert.equal((result.model as { isError?: boolean }[])[0]!.isError, true);
		} finally {
			await otherClient.close();
			await otherServer.close();
			await other.close();
			systemctl("unmask", "--runtime", masked);
		}
	});

	test("at start, what a crash left of the slice's scopes is settled: the running stopped, the failed reset", async () => {
		const left = `${prefix}99-left.scope`;
		const hog = `${prefix}98-oom.scope`;
		const sleeper = spawn("systemd-run", ["--user", "--scope", "--quiet", `--unit=${left}`, `--slice=${slice}`, "--", "sleep", "304"], { stdio: "ignore" });
		const exited = new Promise((resolve) => sleeper.once("exit", resolve));
		spawnSync("systemd-run", ["--user", "--scope", "--quiet", `--unit=${hog}`, `--slice=${slice}`, "--", "python3", "-c", "a = bytearray(600 << 20)"]);
		await until(() => property(left, "ActiveState") === "active");
		assert.equal(property(hog, "ActiveState"), "failed");
		const reconciled = await CommandScopes.open({ slice });
		reconciled.close();
		await exited;
		assert.deepEqual(units(prefix).filter((unit) => unit === left || unit === hog), []);
	});
});
