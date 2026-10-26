// The search index's writer thread during a backfill (./writer.ts): its own connection to the index file, each write
// as the server's thread would have made it, acknowledged so the server keeps only a few batches ahead.
import { parentPort, workerData } from "node:worker_threads";
import { SearchIndex } from "./index.ts";
import { UsageLedger } from "./usage.ts";
import type { WriteMessage } from "./writer.ts";

const index = new SearchIndex((workerData as { path: string }).path);
const usage = new UsageLedger(index.db);

parentPort!.on("message", (message: WriteMessage | { type: "close" }) => {
	switch (message.type) {
		case "close":
			index.close();
			parentPort!.close();
			return;
		case "add":
			index.add(message.entries);
			usage.add(message.usage);
			break;
		case "title":
			index.setTitle(message.conversationId, message.title);
			break;
		case "archived":
			index.setArchived(message.conversationId, message.archived);
			break;
		case "conversation":
			index.setConversation(message.conversationId, message.info);
			break;
		case "warm":
			usage.addWarm(message.row);
			break;
		case "compaction":
			usage.addCompaction(message.row);
			break;
	}
	parentPort!.postMessage(null);
});
