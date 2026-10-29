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
import { createCodingTools, type ImageProcessor } from "@earendil-works/pi-durable/tools";
import { createNodePhotonImages } from "@earendil-works/pi-durable/images/node";
import { createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { CacheWarmer, type CacheWarmingMode } from "./cache.ts";
import { type CompactionThreshold, compactionOverrides, DEFAULT_COMPACTION_THRESHOLD, FollowUpCompaction } from "./compaction.ts";
import { CompactionLog } from "./compactions.ts";
import { DEV_MODEL, devProvider } from "./dev-model.ts";
import { Serial } from "./serial.ts";
import { skillsSection } from "./skills.ts";
import { Subagent } from "./subagent.ts";
import { FileStore } from "./files.ts";
import { sendFileExtension } from "./send-file.ts";

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
	 * Out of every chat list and search, on every device, by Hide. Kept, as every conversation is: durable deletes
	 * none.
	 */
	hidden?: boolean;
	/** Pinned to the top of its list, as Telegram pins chats: when, so later pins sit higher. */
	pinned?: number;
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
	/** When prompt caches are kept warm (src/cache.ts); "idle" until a client changes it. */
	cacheWarming?: CacheWarmingMode;
	/** When compaction starts (src/compaction.ts); 90% of the window, at most 700k tokens, until a client changes it. */
	compaction?: CompactionThreshold;
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
	/** A prompt cache lifetime for the dev model, in seconds, with prices to make warming it pay: to try warming. */
	devCacheTtl?: number;
	onReport?: (error: unknown, info: ReportInfo) => void;
	/** Whose `.agents/skills` the prompt lists besides the conversation directory's (src/skills.ts); default home. */
	skillsHome?: string;
	/** Where files are kept (src/files.ts); default beside the database (`tau.db`'s `tau.files`), or a temporary one. */
	files?: string;
	/** The largest file a message or `send_file` may carry; default 1 GB. */
	maxFileBytes?: number;
};

export type Host = {
	readonly harness: Harness;
	readonly storage: Storage;
	readonly models: MutableModels;
	readonly serverId: string;
	/** The SQLite file, when not in memory. */
	readonly database?: string;
	/** The model new conversations get: the one set from a client, else `--model`. */
	readonly defaultModel: ModelRef;
	setDefaultModel(model: ModelRef): Promise<void>;
	/** The thinking level new conversations get, fitted to their model; "off" until a client sets one. */
	readonly defaultThinkingLevel: ModelThinkingLevel;
	setDefaultThinkingLevel(level: ModelThinkingLevel): Promise<void>;
	/** Orders the requests that change a conversation, across connections (src/serial.ts). */
	readonly serial: Serial;
	/** Keeps working conversations' prompt caches warm (src/cache.ts). */
	readonly cache: CacheWarmer;
	readonly cacheWarming: CacheWarmingMode;
	setCacheWarming(mode: CacheWarmingMode): Promise<void>;
	/** Compaction as a follow-up to the conversation's cached context (src/compaction.ts). */
	readonly compaction: FollowUpCompaction;
	readonly compactionThreshold: CompactionThreshold;
	/** What became of each compaction, for the app's card (src/compactions.ts). */
	readonly compactions: CompactionLog;
	setCompactionThreshold(threshold: CompactionThreshold): Promise<void>;
	readonly cwd: string;
	/** The files messages refer to (src/files.ts). */
	readonly files: FileStore;
	/**
	 * Shrinks and converts images for the model (durable's Photon one, in a worker thread): an image the read tool
	 * returns, a photo past the limits.
	 */
	readonly images: ImageProcessor;
	close(): Promise<void>;
};

const PREAMBLE = `You are tau, a coding agent reached from a phone. Be concise: answers are read on a small screen.
Use the tools to inspect and change files and run commands. You start in the working directory below; the user does not
pick one, so go where the work is (absolute paths, or \`cd\` in a command). In a repository, read its AGENTS.md first,
and look for its own skills in .agents/skills.
Files the user attaches are named at the start of their message, in <attachments>, each at its path: an <image> is also
shown to you, a <file> only named. They are kept with the chat, read-only: use them where they are, and copy one to
change it. send_file sends files to the user.
Words the user quotes from this chat are in <tau:quote>, their reply after each.`;

export async function openHost(options: HostOptions = {}): Promise<Host> {
	const context = BACKGROUND_CONTEXT;
	const cwd = options.cwd ?? homedir();
	let defaultModel = options.model ?? DEV_MODEL;

	const models = createModels({ credentials: options.credentials });
	for (const provider of builtinProviders()) models.setProvider(provider);
	models.setProvider(devProvider({ tokensPerSecond: options.devTokensPerSecond, cacheTtl: options.devCacheTtl }).provider);
	let cacheWarming: CacheWarmingMode = "idle";
	const cache = new CacheWarmer({ mode: () => cacheWarming });
	// Provider errors that may pass are asked again for a long while, as pi does: an agent left working should not stop
	// for an overloaded provider. With 2 s doubling to a minute, 32 retries wait about half an hour.
	const retry = { maxRetries: 32, baseDelayMs: 2000, maxAgentDelayMs: 60_000 };
	const compaction = new FollowUpCompaction({ retry: () => retry });
	let compactionThreshold: CompactionThreshold = DEFAULT_COMPACTION_THRESHOLD;

	const files = new FileStore(options.files ?? (options.database === undefined ? undefined : `${options.database.replace(/\.db$/, "")}.files`), {
		...(options.maxFileBytes === undefined ? {} : { maxBytes: options.maxFileBytes }),
	});
	const registry = createRegistry();
	// Without one, the read tool refuses an image past 2000 pixels or 4.5 MB instead of shrinking it, as pi's does.
	const images = await createNodePhotonImages();
	registry.install(createCodingTools({ images }));
	registry.install(Subagent);
	registry.install(sendFileExtension(files));
	// Code mode (docs/codemode.md): the model's scripts call the tools, each script in a QuickJS worker of its own. No
	// `models.*`: classifiers and image models need providers tau does not set up.
	const sandbox = new CodemodeSandbox({ memoryLimitBytes: 256 * 1024 * 1024 });
	registry.install(createCodemodeExtension({ sandbox, models: false }));
	registry.install(
		defineExtension({
			name: "tau",
			sections: [
				section("preamble", () => PREAMBLE, { tag: false }),
				section("cwd", (input) => input.env?.cwd),
				skillsSection(options.skillsHome),
			],
			hooks: [cache.hook, compaction.hook],
		}),
	);

	let storage: Storage;
	if (options.database === undefined) storage = new MemoryStorage();
	else {
		mkdirSync(dirname(options.database), { recursive: true });
		storage = await openNodeSqliteStorage(options.database);
	}

	// The dev model's chats are short: a manual compaction there keeps little verbatim, so it has something to summarize.
	const ownOverrides = { [`${DEV_MODEL.provider}/${DEV_MODEL.modelId}`]: { keepRecentTokens: 200 } };
	// Read by the harness at each use; the per-model thresholds are worked out again only when the setting changes.
	let settings: HarnessSettings = {};
	const updateSettings = () => {
		settings = { toolExecution: "parallel", retry, compaction: { modelOverrides: compactionOverrides(models, compactionThreshold, ownOverrides) } };
	};
	updateSettings();
	const harness = await Harness.open(
		storage,
		{
			models: cache.wrap(models),
			registry,
			settings: () => settings,
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
	cache.attach(harness, async (id) => (await storage.conversation(id, context))?.owner !== undefined);
	compaction.attach(harness);
	const compactions = new CompactionLog(harness, compaction);
	const serverId = await harness.commit(async (tx) => {
		const doc = await tx.doc(ServerDoc);
		if (doc.id === "") doc.id = randomUUID();
		return doc.id;
	}, context);
	const savedSettings = await harness.snapshot(SettingsDoc, context);
	if (savedSettings?.defaultModel !== undefined) defaultModel = savedSettings.defaultModel;
	let defaultThinkingLevel: ModelThinkingLevel = savedSettings?.defaultThinkingLevel ?? "off";
	if (savedSettings?.cacheWarming !== undefined) cacheWarming = savedSettings.cacheWarming;
	if (savedSettings?.compaction !== undefined) {
		compactionThreshold = savedSettings.compaction;
		updateSettings();
	}
	// Continue runs the last process left unfinished.
	harness.resume();

	return {
		harness,
		storage,
		models,
		serverId,
		...(options.database === undefined ? {} : { database: options.database }),
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
		cache,
		get cacheWarming() {
			return cacheWarming;
		},
		async setCacheWarming(mode) {
			await harness.commit(async (tx) => {
				(await tx.doc(SettingsDoc)).cacheWarming = mode;
			}, context);
			cacheWarming = mode;
			cache.modeChanged();
		},
		compaction,
		compactions,
		get compactionThreshold() {
			return compactionThreshold;
		},
		async setCompactionThreshold(threshold) {
			await harness.commit(async (tx) => {
				(await tx.doc(SettingsDoc)).compaction = { ...threshold };
			}, context);
			compactionThreshold = threshold;
			updateSettings();
		},
		cwd,
		files,
		images,
		close: async () => {
			cache.close();
			compactions.close();
			await harness.close(context);
			await sandbox.close();
			files.close();
		},
	};
}
