// The driver of scripts/oom-repro.sh: a chat on the dev model runs `command` through bash, and this prints what the
// model got back, following the server across a restart (its data is on disk, so the interrupted call settles there).
// With a neighbor command, another chat runs that one first, to its end, and prints its result.
//   node --no-warnings scripts/oom-repro.ts <ws-url> <command> [<neighbor command>]
import { ConversationReplica, type Entry, TauClient } from "../server/src/client.ts";

const [url, command, neighbor] = process.argv.slice(2) as [string, string, string | undefined];
const log = (line: string) => console.log(`[driver] ${line}`);

async function connect(deadline: number): Promise<TauClient> {
	for (;;) {
		try {
			const client = await TauClient.connect(url);
			await client.request("hello", { protocol: 1 });
			return client;
		} catch (error) {
			if (Date.now() > deadline) throw error;
			await new Promise((resolve) => setTimeout(resolve, 500));
		}
	}
}

const text = (entry: Entry | undefined) =>
	((entry?.model as { content?: { type: string; text?: string }[] }[] | undefined)?.[0]?.content ?? []).map((part) => part.text ?? "").join("");
const result = (replica: ConversationReplica) => replica.ordered().find((entry) => entry.kind === "pi.tool-result");
const answered = (replica: ConversationReplica) => {
	const call = result(replica);
	return call !== undefined && replica.ordered().some((entry) => entry.kind === "pi.assistant" && entry.id > call.id) && (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined;
};

let client = await connect(Date.now() + 30_000);
if (neighbor !== undefined) {
	const { dialog } = await client.request("conversation.create", { title: "OOM repro neighbor", agent: { model: { provider: "dev", modelId: "echo" } } });
	const replica = new ConversationReplica(dialog.conversation.id as number);
	await replica.sync(client);
	await client.request("conversation.submit", { conversationId: replica.id, requestId: "neighbor", content: `$ ${neighbor}` });
	log(`chat ${replica.id}: sent "$ ${neighbor}"`);
	await new Promise<void>((resolve) => {
		if (answered(replica)) resolve();
		const stop = replica.onChange(() => answered(replica) && (stop(), resolve()));
	});
	log(`its tool result: ${text(result(replica)).trim()}`);
}
const { dialog } = await client.request("conversation.create", { title: "OOM repro", agent: { model: { provider: "dev", modelId: "echo" } } });
const id = dialog.conversation.id as number;
let replica = new ConversationReplica(id);
await replica.sync(client);
await client.request("conversation.submit", { conversationId: id, requestId: "hog", content: `$ ${command}` });
log(`chat ${id}: sent "$ ${command}"`);
const started = Date.now();
let drops = 0;
for (;;) {
	const outcome = await Promise.race([
		new Promise<"done">((resolve) => {
			if (answered(replica)) resolve("done");
			const stop = replica.onChange(() => {
				if (!answered(replica)) return;
				stop();
				resolve("done");
			});
		}),
		client.closed.then(() => "dropped" as const),
		new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), 120_000)),
	]);
	if (outcome === "done") break;
	if (outcome === "timeout") {
		log("no answer within two minutes");
		break;
	}
	drops += 1;
	log(`connection dropped after ${((Date.now() - started) / 1000).toFixed(1)} s (the server went away); reconnecting`);
	client = await connect(Date.now() + 60_000);
	log("reconnected");
	replica = new ConversationReplica(id);
	await replica.sync(client);
}
log(`server restarts seen by the driver: ${drops}`);
const call = result(replica);
log(`tool result (isError ${(call?.model as { isError?: boolean }[] | undefined)?.[0]?.isError === true}):`);
console.log(text(call).split("\n").map((line) => `    ${line}`).join("\n"));
const answer = replica.ordered().findLast((entry) => entry.kind === "pi.assistant");
log(`the model's next answer: ${text(answer).split("\n")[0]}`);
await client.close();
