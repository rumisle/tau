// Checks a built release (scripts/build-release.sh) the way it runs: from its directory, on a database of its own, so
// every worker the bundle starts from beside itself starts: a command, code mode (QuickJS's worker), and the search
// index rebuilt from the database on a second start (the index's worker). Usage (from server/):
//   node ../scripts/check-release.ts <release dir>
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { ConversationReplica, TauClient } from "../server/src/client.ts";

const given = process.argv[2];
if (given === undefined) throw new Error("usage: check-release.ts <release dir>");
const dir = resolve(given);
const data = mkdtempSync(join(tmpdir(), "tau-release-check-"));
const failures: string[] = [];
let log = "";

async function start(): Promise<{ server: ChildProcess; client: TauClient }> {
	const server = spawn(process.execPath, ["--no-warnings", join(dir, "tau-server.js"), "--data", data, "--port", "0", "--model", "dev/echo"], {
		cwd: tmpdir(),
		stdio: ["ignore", "pipe", "pipe"],
	});
	let own = "";
	const url = await new Promise<string>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`it did not listen:\n${own}`)), 15_000);
		const read = (chunk: Buffer) => {
			own += chunk;
			log += chunk;
			const match = /tau listening on (ws:\/\/\S+)/.exec(own);
			if (match) {
				clearTimeout(timer);
				resolve(match[1]!);
			}
		};
		server.stdout.on("data", read);
		server.stderr.on("data", read);
		server.on("exit", (code) => reject(new Error(`it exited (${code}):\n${own}`)));
	});
	const client = await TauClient.connect(url);
	await client.request("hello", { protocol: 1 });
	return { server, client };
}

async function stop({ server, client }: { server: ChildProcess; client: TauClient }): Promise<void> {
	await client.close().catch(() => {});
	const exited = new Promise((resolve) => server.once("exit", resolve));
	server.kill();
	await exited;
}

const until = async (check: () => Promise<boolean>, ms: number) => {
	const begin = Date.now();
	while (Date.now() - begin < ms) {
		if (await check()) return true;
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	return false;
};

let running: { server: ChildProcess; client: TauClient } | undefined;
try {
	running = await start();
	const { client } = running;
	const hello = (await client.request("hello", { protocol: 1 })) as { piRevision?: string };
	if (!hello.piRevision) failures.push("hello has no piRevision");
	const { dialog } = (await client.request("conversation.create", { title: "release check" })) as { dialog: { conversation: { id: number } } };
	const replica = new ConversationReplica(dialog.conversation.id);
	await replica.sync(client);
	const ask = async (content: string, expect: string, what: string) => {
		const { submission } = (await client.request("conversation.submit", { conversationId: replica.id, requestId: what, content })) as { submission: { id: number } };
		await until(async () => replica.submissions.get(submission.id)?.status === "done" && (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined, 20_000);
		if (!JSON.stringify([...replica.entries.values()]).includes(expect)) failures.push(`${what}: no "${expect}"`);
	};
	await ask("$ echo bash-$((6*7))", "bash-42", "a command");
	await ask("!code return 'codemode-' + (6*7)", "codemode-42", "code mode");
	await ask("zanzibarquokka", "zanzibarquokka", "a message");
	await stop(running);
	running = undefined;

	// Without its index, the server builds it again from the database at start, in the index's worker.
	for (const file of readdirSync(data)) if (file.includes(".search.")) rmSync(join(data, file), { force: true });
	running = await start();
	const again = running.client;
	const found = await until(async () => {
		const result = (await again.request("search", { query: "zanzibarquokka" })) as { results?: unknown[] };
		return (result.results?.length ?? 0) > 0;
	}, 15_000);
	if (!found) failures.push("search: the index built again at start does not have the message (the index's worker)");
	await new Promise((resolve) => setTimeout(resolve, 300));
	if (/Cannot find module|failed/i.test(log)) failures.push(`the log has an error:\n${log}`);
} catch (error) {
	failures.push(String(error));
} finally {
	if (running !== undefined) await stop(running);
	rmSync(data, { recursive: true, force: true });
}
if (failures.length > 0) {
	console.error(`release check failed:\n- ${failures.join("\n- ")}`);
	process.exit(1);
}
console.log("release check: a command, code mode, the search index built again");
