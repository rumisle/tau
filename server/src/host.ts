// The Harness tau serves: storage, models, tools, and tau's own documents.
import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { CredentialStore, ModelThinkingLevel, MutableModels } from "@earendil-works/pi-ai";
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
	type ReportInfo,
	type Storage,
	section,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { DEV_MODEL, devProvider } from "./dev-model.ts";
import { Serial } from "./serial.ts";
import { Subagent } from "./subagent.ts";

/** Per-conversation metadata the chat list shows. */
export type MetaState = {
	title?: string;
	createdAt?: number;
	/** The server replaces the title after the first answer (src/titles.ts). */
	autoTitle?: boolean;
	/** The last entry the user has seen; later assistant messages count as unread. */
	read?: number;
	/** Marked unread by hand, as Telegram's "Mark as Unread"; reading the conversation clears it. */
	markedUnread?: boolean;
	/** Out of the main chat list, in Archived Chats. */
	archived?: boolean;
	/**
	 * Request IDs withdrawn before any submission had them, newest last: a submit that arrives later with one is
	 * refused, so a message cancelled while its submit was in flight can never be admitted.
	 */
	withdrawn?: string[];
};
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

/** Conversations created per client request ID, so a retried `conversation.create` returns the first one. */
export const CreatesDoc = defineDoc<{ requests: Record<string, number>; order: string[] }>({
	kind: "tau.creates",
	version: 1,
	scope: "session",
	initial: () => ({ requests: {}, order: [] }),
});

/** Settings a client changes for the whole server. */
export const SettingsDoc = defineDoc<{
	defaultModel?: ModelRef;
	defaultThinkingLevel?: ModelThinkingLevel;
	/** Where pushes go (src/notifier.ts); none until a client turns them on. */
	ntfy?: { server: string; topic: string };
}>({
	kind: "tau.settings",
	version: 1,
	scope: "session",
	initial: () => ({}),
});

export type HostOptions = {
	/** SQLite file; omitted: in memory. */
	database?: string;
	/** Default model for new conversations. */
	model?: ModelRef;
	/** Working directory of conversations that set none; default the home directory. */
	cwd?: string;
	credentials?: CredentialStore;
	/** Speed of the dev model, for tests. */
	devTokensPerSecond?: number;
	onReport?: (error: unknown, info: ReportInfo) => void;
};

export type Host = {
	readonly harness: Harness;
	readonly storage: Storage;
	readonly models: MutableModels;
	readonly serverId: string;
	/** The model new conversations get: the one set from a client, else `--model`. */
	readonly defaultModel: ModelRef;
	setDefaultModel(model: ModelRef): Promise<void>;
	/** The thinking level new conversations get, fitted to their model; "off" until a client sets one. */
	readonly defaultThinkingLevel: ModelThinkingLevel;
	setDefaultThinkingLevel(level: ModelThinkingLevel): Promise<void>;
	/** Orders the requests that change a conversation, across connections (src/serial.ts). */
	readonly serial: Serial;
	readonly cwd: string;
	close(): Promise<void>;
};

const PREAMBLE = `You are tau, a coding agent reached from a phone. Be concise: answers are read on a small screen.
Use the tools to inspect and change files and run commands in the working directory.`;

export async function openHost(options: HostOptions = {}): Promise<Host> {
	const context = BACKGROUND_CONTEXT;
	const cwd = options.cwd ?? homedir();
	let defaultModel = options.model ?? DEV_MODEL;

	const models = createModels({ credentials: options.credentials });
	for (const provider of builtinProviders()) models.setProvider(provider);
	models.setProvider(devProvider({ tokensPerSecond: options.devTokensPerSecond }).provider);

	const registry = createRegistry();
	registry.install(CodingTools);
	registry.install(Subagent);
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

	// The dev model's chats are short: a manual compaction there keeps little verbatim, so it has something to summarize.
	// Provider errors that may pass are asked again for a long while, as pi does: an agent left working should not stop
	// for an overloaded provider. With 2 s doubling to a minute, 32 retries wait about half an hour.
	const settings: HarnessSettings = { toolExecution: "parallel", retry: { maxRetries: 32 }, compaction: { modelOverrides: { [`${DEV_MODEL.provider}/${DEV_MODEL.modelId}`]: { keepRecentTokens: 200 } } } };
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
			onReport: (error, info) => {
				if (options.onReport !== undefined) options.onReport(error, info);
				else console.error(`[durable] ${info.type}:`, error);
			},
		},
		context,
	);
	const serverId = await harness.commit(async (tx) => {
		const doc = await tx.doc(ServerDoc);
		if (doc.id === "") doc.id = randomUUID();
		return doc.id;
	}, context);
	const savedSettings = await harness.snapshot(SettingsDoc, context);
	if (savedSettings?.defaultModel !== undefined) defaultModel = savedSettings.defaultModel;
	let defaultThinkingLevel: ModelThinkingLevel = savedSettings?.defaultThinkingLevel ?? "off";
	// Continue runs the last process left unfinished.
	harness.resume();

	return {
		harness,
		storage,
		models,
		serverId,
		get defaultModel() {
			return defaultModel;
		},
		async setDefaultModel(model) {
			await harness.commit(async (tx) => {
				(await tx.doc(SettingsDoc)).defaultModel = model;
			}, context);
			defaultModel = model;
		},
		get defaultThinkingLevel() {
			return defaultThinkingLevel;
		},
		async setDefaultThinkingLevel(level) {
			await harness.commit(async (tx) => {
				(await tx.doc(SettingsDoc)).defaultThinkingLevel = level;
			}, context);
			defaultThinkingLevel = level;
		},
		serial: new Serial(),
		cwd,
		close: () => harness.close(context),
	};
}
