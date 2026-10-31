// Drives a running tau server through the protocol, for checks across versions of a database (docs/deploy.md, rolling
// back across a pi bump) and the cost of runs:
//   node --no-warnings bench/runs.ts <url> check            open every chat (subscribe and unsubscribe), count failures
//   node --no-warnings bench/runs.ts <url> write            a dev/echo chat with an answer and a tool round
//   node --no-warnings bench/runs.ts <url> runs <n> [pid]   read every chat, then n runs in a new chat: latency, and the
//                                                           server's CPU when given its pid (Linux, /proc)
//   node --no-warnings bench/runs.ts <url> many <n>,<m> [pid]  n more chats with a run each (32 at once), then m runs
//                                                           in one chat: what the scheduler's work per commit costs
//                                                           as conversations grow
//
// On a copy of chorus's database (211 chats), 32 cores, Node 24, dev/echo at 4,000 tokens a second:
//
//   | pi       | runs in one chat, 211 chats | 2,000 more chats with a run | then a run   | 4,000 more   | then a run   |
//   |----------|-----------------------------|-----------------------------|--------------|--------------|--------------|
//   | 4b535d57 | 13 ms, 9 ms CPU             | 7.1 s, 4.0 ms CPU each      | 16 ms, 11 ms | 17.7 s, 4.8  | 22 ms, 16 ms |
//   | 35dfa757 | 13 ms, 9 ms CPU             | 5.1 s, 3.1 ms CPU each      | 13 ms, 7 ms  | 10.4 s, 3.0  | 13 ms, 7 ms  |
//
// Before 35dfa757 every commit re-walked each conversation run in the last 10 minutes, so a run cost more as they grew;
// since, it costs the same.
// Start the server on a .backup copy, never the real database, with no credentials, e.g.
//   PI_CODING_AGENT_DIR=/tmp/empty node --no-warnings src/main.ts --db /tmp/copy/tau.db --port 7973 --dev-tps 4000
import { readFileSync } from "node:fs";
import { ConversationReplica, TauClient } from "../src/client.ts";

const [url, mode, arg, pidArg] = process.argv.slice(2);
const client = await TauClient.connect(url!);
await client.request("hello", { protocol: 1 });
const cpu = (pid: string) => { const f = readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1]!.split(" "); return (Number(f[11]) + Number(f[12])) * 10; };

async function all(): Promise<number[]> {
	const list = (await client.request("dialogs.subscribe", {})) as { dialogs: { conversation: { id: number } }[] };
	return list.dialogs.map((dialog) => dialog.conversation.id);
}

if (mode === "check") {
	const ids = await all();
	let ok = 0, failed: string[] = [], entries = 0;
	for (const id of ids) {
		try {
			const result = await client.request("conversation.subscribe", { conversationId: id, limit: 50 });
			entries += result.entries.length; ok++;
			await client.request("conversation.unsubscribe", { conversationId: id });
		} catch (error) { failed.push(`${id}: ${(error as Error).message}`); }
	}
	console.log(`chats ${ids.length}, opened ${ok}, entries ${entries}, failed ${failed.length}`, failed.slice(0, 5));
} else if (mode === "write") {
	// New-version commits: a dev chat with an answer, a tool call, and a model error on a real chat.
	const { dialog } = await client.request("conversation.create", { title: "Rollback check", agent: { model: { provider: "dev", modelId: "echo" } } });
	const replica = new ConversationReplica(dialog.conversation.id);
	await replica.sync(client);
	for (const content of ["hello from the new server", "$ echo tool round"]) {
		const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: content, content });
		await waitDone(replica, submission.id);
	}
	console.log(`wrote chat ${replica.id}, entries ${replica.entries.size}`);
} else if (mode === "runs") {
	const n = Number(arg ?? 20);
	// Every chat read first, so the old scheduler has them all to walk after each commit.
	const ids = await all();
	for (const id of ids) { await client.request("conversation.subscribe", { conversationId: id, limit: 5 }); }
	const { dialog } = await client.request("conversation.create", { title: "Runs", agent: { model: { provider: "dev", modelId: "echo" } } });
	const replica = new ConversationReplica(dialog.conversation.id);
	await replica.sync(client);
	const times: number[] = [];
	const cpu0 = pidArg ? cpu(pidArg) : 0;
	const t0 = performance.now();
	for (let i = 0; i < n; i++) {
		const t = performance.now();
		const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: `run-${i}`, content: i % 2 === 0 ? `run ${i}` : "$ echo tool" });
		await waitDone(replica, submission.id);
		times.push(performance.now() - t);
	}
	const wall = performance.now() - t0;
	const used = pidArg ? cpu(pidArg) - cpu0 : 0;
	times.sort((a, b) => a - b);
	console.log(`${ids.length} chats read; ${n} runs: median ${times[n >> 1]!.toFixed(0)} ms, p90 ${times[Math.floor(n * 0.9)]!.toFixed(0)} ms, wall ${(wall / 1000).toFixed(1)} s, server CPU ${used} ms (${(used / n).toFixed(0)} ms/run)`);
}
if (mode === "many") {
	// N more chats, each with one run (so the scheduler holds their context), then M runs in one more chat.
	const [n, m] = (arg ?? "2000,40").split(",").map(Number) as [number, number];
	const ids: number[] = [];
	for (let i = 0; i < n; i++) ids.push((await client.request("conversation.create", { title: `Many ${i}`, agent: { model: { provider: "dev", modelId: "echo" } } })).dialog.conversation.id);
	let cpu0 = pidArg ? cpu(pidArg) : 0;
	let t0 = performance.now();
	let next = 0;
	await Promise.all(Array.from({ length: 32 }, async () => {
		while (next < ids.length) {
			const id = ids[next++]!;
			const replica = new ConversationReplica(id);
			await replica.sync(client);
			const { submission } = await client.request("conversation.submit", { conversationId: id, requestId: `m-${id}`, content: `hello ${id}` });
			await waitDone(replica, submission.id);
			await client.request("conversation.unsubscribe", { conversationId: id });
		}
	}));
	const warm = performance.now() - t0;
	const warmCpu = pidArg ? cpu(pidArg) - cpu0 : 0;
	const { dialog } = await client.request("conversation.create", { title: "Runs", agent: { model: { provider: "dev", modelId: "echo" } } });
	const replica = new ConversationReplica(dialog.conversation.id);
	await replica.sync(client);
	const times: number[] = [];
	cpu0 = pidArg ? cpu(pidArg) : 0;
	t0 = performance.now();
	for (let i = 0; i < m; i++) {
		const t = performance.now();
		const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId: `run-${i}`, content: i % 2 === 0 ? `run ${i}` : "$ echo tool" });
		await waitDone(replica, submission.id);
		times.push(performance.now() - t);
	}
	const wall = performance.now() - t0;
	const used = pidArg ? cpu(pidArg) - cpu0 : 0;
	times.sort((a, b) => a - b);
	console.log(`${n} chats with a run (32 at once): ${(warm / 1000).toFixed(1)} s, CPU ${(warmCpu / 1000).toFixed(1)} s (${(warmCpu / n).toFixed(1)} ms/run); then ${m} runs in one chat: median ${times[m >> 1]!.toFixed(0)} ms, p90 ${times[Math.floor(m * 0.9)]!.toFixed(0)} ms, CPU ${(used / m).toFixed(0)} ms/run`);
}
await client.close();

function waitDone(replica: ConversationReplica, id: number): Promise<void> {
	const done = () => replica.submissions.get(id)?.status === "done" && (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined;
	if (done()) return Promise.resolve();
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("timed out")), 60_000);
		const stop = replica.onChange(() => { if (done()) { clearTimeout(timer); stop(); resolve(); } });
	});
}
