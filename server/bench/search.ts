// Search benchmark: indexes the prompts, answers and reasoning of the pi sessions in ~/.pi/agent/sessions (or the
// directory given) as conversations, then times queries of each kind.
//   node --no-warnings bench/search.ts [sessions-dir] [--db /tmp/tau-search-bench.db] [--keep]
import { readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Kind, type IndexEntry, SearchIndex } from "../src/search/index.ts";

const args = process.argv.slice(2);
const dbIndex = args.indexOf("--db");
const dbPath = dbIndex >= 0 ? args[dbIndex + 1]! : "/tmp/tau-search-bench.db";
const keep = args.includes("--keep");
const root = args.find((arg, index) => !arg.startsWith("--") && args[index - 1] !== "--db" && args[index - 1] !== "--scale") ?? join(homedir(), ".pi/agent/sessions");

function files(dir: string): string[] {
	const out: string[] = [];
	for (const name of readdirSync(dir)) {
		const path = join(dir, name);
		if (statSync(path).isDirectory()) out.push(...files(path));
		else if (name.endsWith(".jsonl")) out.push(path);
	}
	return out;
}

type Block = { type: string; text?: string; thinking?: string };
const texts = new Map<string, string>();
const titles = new Map<number, string>();
const conversations: IndexEntry[][] = [];
let chars = 0;
let nextId = 1;
for (const file of files(root).sort()) {
	const conversationId = nextId++;
	const entries: IndexEntry[] = [];
	for (const line of readFileSync(file, "utf8").split("\n")) {
		if (!line.startsWith('{"type":"message"')) continue;
		let record: { timestamp: string; message: { role: string; content: string | Block[] } };
		try {
			record = JSON.parse(line);
		} catch {
			continue;
		}
		const { role, content } = record.message;
		if (role !== "user" && role !== "assistant") continue;
		const blocks: Block[] = typeof content === "string" ? [{ type: "text", text: content }] : content;
		const parts: IndexEntry["parts"] = [];
		blocks.forEach((block, idx) => {
			const text = block.type === "text" ? block.text : block.type === "thinking" ? block.thinking : undefined;
			if (text === undefined || text.trim() === "") return;
			const kind = role === "user" ? Kind.user : block.type === "thinking" ? Kind.reasoning : Kind.assistant;
			parts.push({ kind, text, idx });
		});
		if (parts.length === 0) continue;
		const entryId = nextId++;
		for (const part of parts) {
			texts.set(`${entryId}:${part.idx}`, part.text);
			chars += part.text.length;
		}
		if (!titles.has(conversationId) && role === "user") titles.set(conversationId, parts[0]!.text.slice(0, 60));
		entries.push({ conversationId, entryId, time: Date.parse(record.timestamp), parts });
	}
	if (entries.length > 0) conversations.push(entries);
}
// --scale N: the corpus N times over, as other conversations, to see how searches grow with the index.
const scaleIndex = args.indexOf("--scale");
const scale = scaleIndex >= 0 ? Number(args[scaleIndex + 1]) : 1;
if (scale > 1) {
	const base = conversations.slice();
	for (let copy = 1; copy < scale; copy++) {
		for (const list of base) {
			const conversationId = nextId++;
			titles.set(conversationId, titles.get(list[0]!.conversationId) ?? "");
			conversations.push(
				list.map((entry) => {
					const entryId = nextId++;
					for (const part of entry.parts) texts.set(`${entryId}:${part.idx}`, part.text);
					return { ...entry, conversationId, entryId, time: entry.time - copy * 30 * 86_400_000 };
				}),
			);
		}
	}
	chars *= scale;
}
const entryCount = conversations.reduce((sum, list) => sum + list.length, 0);
console.log(`corpus: ${conversations.length} conversations, ${entryCount} entries, ${(chars / 1e6).toFixed(1)}M chars`);

if (!keep) for (const suffix of ["", "-wal", "-shm"]) rmSync(dbPath + suffix, { force: true });
const index = new SearchIndex(dbPath);
let started = performance.now();
if (!keep) {
	// As the server indexes: a conversation's entries in batches, as commits bring them.
	for (const list of conversations) {
		for (let i = 0; i < list.length; i += 64) index.add(list.slice(i, i + 64));
		index.setTitle(list[0]!.conversationId, titles.get(list[0]!.conversationId) ?? "");
	}
	const ms = performance.now() - started;
	index.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
	const size = statSync(dbPath).size;
	console.log(`index: ${(ms / 1000).toFixed(1)} s, ${((chars / 1e6) / (ms / 1000)).toFixed(1)}M chars/s, ${(size / 1e6).toFixed(0)} MB`);
	started = performance.now();
	index.db.exec("INSERT INTO fts (fts) VALUES ('optimize')");
	console.log(`optimize: ${((performance.now() - started) / 1000).toFixed(1)} s, ${(statSync(dbPath).size / 1e6).toFixed(0)} MB`);
}

const load = async (conversationId: number, entryId: number, idx: number) => (idx < 0 ? titles.get(conversationId) : texts.get(`${entryId}:${idx}`));
const queries: [string, string, boolean][] = [
	["common word", "the", false],
	["common word", "file", false],
	["rare word", "wallpaper", false],
	["identifier part", "palette", false],
	["two words", "cache miss", false],
	["three words", "telegram chat list", false],
	["phrase", '"context window"', false],
	["typo", "compacton", false],
	["CJK", "压缩", false],
	["exclude", "server -tailscale", false],
	["typing 2 letters", "co", true],
	["typing 3 letters", "com", true],
	["typing a word", "compac", true],
	["typing second word", "chat lis", true],
];
const rows: string[] = [];
for (const [label, query, typing] of queries) {
	const times: number[] = [];
	let total = 0;
	let first = "";
	for (let i = 0; i < 7; i++) {
		const t = performance.now();
		const response = await index.search(query, load, { typing, limit: 20 });
		times.push(performance.now() - t);
		total = response.total;
		first = response.results[0]?.hits[0]?.text.replace(/\s+/g, " ").slice(0, 50) ?? "";
	}
	times.sort((a, b) => a - b);
	rows.push(`${label.padEnd(20)} ${JSON.stringify(query).padEnd(22)} ${String(total).padStart(5)} chats  p50 ${times[3]!.toFixed(1).padStart(6)} ms  max ${times[6]!.toFixed(1).padStart(6)} ms  ${first}`);
}
console.log(rows.join("\n"));
const inChat = conversations.reduce((best, list) => (list.length > best.length ? list : best), conversations[0]!);
const t = performance.now();
const found = index.searchConversation(inChat[0]!.conversationId, "the");
console.log(`in one chat (${inChat.length} entries) "the": ${found.hits.length} hits, ${(performance.now() - t).toFixed(1)} ms`);
index.close();
