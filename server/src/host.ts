// The Harness tau serves: storage, models, tools, and tau's own documents.
import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { CredentialStore, MutableModels } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { builtinProviders } from "@earendil-works/pi-ai/providers/all";
import {
	createRegistry,
	defineDoc,
	defineExtension,
	Harness,
	type HarnessSettings,
	type ModelRef,
	MemoryStorage,
	type Storage,
	section,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { DEV_MODEL, devProvider } from "./dev-model.ts";

/** Per-conversation metadata the chat list shows. */
export type MetaState = { title?: string; createdAt?: number };
export const MetaDoc = defineDoc<MetaState>({
	kind: "tau.meta",
	version: 1,
	scope: "conversation",
	history: "latest",
	fork: "initial",
	initial: () => ({}),
});

/** Identity of this storage; a client whose cache came from another one drops it. */
export const ServerDoc = defineDoc<{ id: string }>({
	kind: "tau.server",
	version: 1,
	scope: "session",
	initial: () => ({ id: "" }),
});

export type HostOptions = {
	/** SQLite file; omitted: in memory. */
	database?: string;
	/** Default model for new conversations. */
	model?: ModelRef;
	/** Working directory of conversations that set none. */
	cwd?: string;
	credentials?: CredentialStore;
	/** Speed of the dev model, for tests. */
	devTokensPerSecond?: number;
	onReport?: (error: unknown) => void;
};

export type Host = {
	readonly harness: Harness;
	readonly storage: Storage;
	readonly models: MutableModels;
	readonly serverId: string;
	readonly defaultModel: ModelRef;
	readonly cwd: string;
	close(): Promise<void>;
};

const PREAMBLE = `You are tau, a coding agent reached from a phone. Be concise: answers are read on a small screen.
Use the tools to inspect and change files and run commands in the working directory.`;

export async function openHost(options: HostOptions = {}): Promise<Host> {
	const context = BACKGROUND_CONTEXT;
	const cwd = options.cwd ?? process.cwd();
	const defaultModel = options.model ?? DEV_MODEL;

	const models = createModels({ credentials: options.credentials });
	for (const provider of builtinProviders()) models.setProvider(provider);
	models.setProvider(devProvider({ tokensPerSecond: options.devTokensPerSecond }).provider);

	const registry = createRegistry();
	registry.install(CodingTools);
	registry.install(
		defineExtension({
			name: "tau",
			sections: [
				section("preamble", () => PREAMBLE, { tag: false }),
				section("cwd", (input) => input.env?.cwd),
			],
		}),
	);

	let storage: Storage;
	if (options.database === undefined) storage = new MemoryStorage();
	else {
		mkdirSync(dirname(options.database), { recursive: true });
		storage = await openNodeSqliteStorage(options.database);
	}

	const settings: HarnessSettings = { toolExecution: "parallel" };
	const harness = await Harness.open(
		storage,
		{
			models,
			registry,
			settings,
			env: ({ cwd: conversationCwd }) => new NodeExecutionEnv({ cwd: conversationCwd ?? cwd }),
			conversationCreated: async (tx, conversation) => {
				const meta = await tx.doc(MetaDoc, conversation.id);
				meta.createdAt ??= Date.now();
			},
			onReport: (error) => {
				if (options.onReport !== undefined) options.onReport(error);
				else console.error("[durable]", error);
			},
		},
		context,
	);
	const serverId = await harness.commit(async (tx) => {
		const doc = await tx.doc(ServerDoc);
		if (doc.id === "") doc.id = randomUUID();
		return doc.id;
	}, context);
	// Continue runs the last process left unfinished.
	harness.resume();

	return {
		harness,
		storage,
		models,
		serverId,
		defaultModel,
		cwd,
		close: () => harness.close(context),
	};
}
