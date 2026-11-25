// pi.dev's catalog over pi-ai's static providers. Opening a picker never fetches: startup and a four-hour timer
// refresh in the background; a search miss can ask once more. The built-ins and the last good cache always remain.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
	getModelType, InMemoryModelsStore, isModelType,
	type AnyModel, type Model, type Api, type ModelsStore, type ModelsStoreEntry,
	type ModelsStoreOperationOptions, type MutableModels, type Provider, type RefreshModelsContext,
} from "@earendil-works/pi-ai";
import { personalizeOpenRouterCatalog } from "@earendil-works/pi-ai/providers/openrouter";

export const MODEL_CATALOG_INTERVAL_MS = 4 * 60 * 60_000;
const MISS_COOLDOWN_MS = 60_000;

export type ModelCatalogOptions = {
	baseUrl?: string;
	fetch?: typeof fetch;
	/** Tests can advance a shorter interval without changing the production policy. */
	intervalMs?: number;
	now?: () => number;
	onError?: (error: unknown) => void;
};

/** One atomic, owner-only file per provider, so concurrent providers cannot overwrite each other's updates. */
export class CatalogStore extends InMemoryModelsStore implements ModelsStore {
	readonly directory?: string;
	constructor(directory?: string) { super(); this.directory = directory; }

	override async read(provider: string, options?: ModelsStoreOperationOptions): Promise<ModelsStoreEntry | undefined> {
		if (this.directory === undefined) return super.read(provider, options);
		options?.signal?.throwIfAborted();
		try {
			const entry = JSON.parse(readFileSync(this.#path(provider), "utf8")) as ModelsStoreEntry;
			if (!Array.isArray(entry.models)) throw new Error("Invalid model catalog cache");
			return { ...entry, models: parseCatalog(provider, entry.models) };
		} catch (error) {
			// A cache is replaceable, not a reason the server cannot start.
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") console.error("[tau] model catalog cache ignored:", error);
			return undefined;
		}
	}

	override async write(provider: string, entry: ModelsStoreEntry, options?: ModelsStoreOperationOptions): Promise<void> {
		if (this.directory === undefined) return super.write(provider, entry, options);
		options?.signal?.throwIfAborted();
		mkdirSync(this.directory, { recursive: true, mode: 0o700 });
		const path = this.#path(provider);
		const temporary = `${path}.${randomUUID()}.tmp`;
		try {
			writeFileSync(temporary, JSON.stringify(entry), { mode: 0o600 });
			renameSync(temporary, path);
		} finally {
			rmSync(temporary, { force: true });
		}
	}

	override async delete(provider: string, options?: ModelsStoreOperationOptions): Promise<void> {
		if (this.directory === undefined) return super.delete(provider, options);
		options?.signal?.throwIfAborted();
		rmSync(this.#path(provider), { force: true });
	}

	#path(provider: string): string { return join(this.directory!, `${encodeURIComponent(provider)}.json`); }
}

function merge(baseline: readonly AnyModel[], overlay: readonly AnyModel[]): AnyModel[] {
	return [...new Map([...baseline, ...overlay].map((model) => [`${getModelType(model)}\0${model.id}`, model])).values()];
}

function parseCatalog(provider: string, value: unknown): AnyModel[] {
	const entries = Array.isArray(value) ? value
		: value !== null && typeof value === "object"
			? ("models" in value && Array.isArray(value.models) ? value.models : Object.values(value)) : undefined;
	if (!entries || entries.some((entry) => entry === null || typeof entry !== "object" || typeof entry.id !== "string")) {
		throw new Error(`Invalid model catalog for ${provider}`);
	}
	return entries.filter((entry) => entry.type === undefined || ["chat", "image", "classifier"].includes(entry.type))
		.map((entry) => ({ ...entry, provider }) as AnyModel);
}

function requestCatalog(provider: string, signal: AbortSignal, options: ModelCatalogOptions, etag?: string): Promise<Response> {
	const url = new URL(`/api/models/providers/${encodeURIComponent(provider)}`, options.baseUrl ?? "https://pi.dev");
	url.searchParams.set("types", "chat,image,classifier");
	return (options.fetch ?? fetch)(url, {
		headers: { accept: "application/json", ...(etag ? { "if-none-match": etag } : {}) },
		signal: AbortSignal.any([signal, AbortSignal.timeout(4000)]),
	});
}

/** Replaces a provider's catalog with what one credential may use (OpenRouter's key). */
export type PersonalizeCatalog = (catalog: readonly AnyModel[], context: RefreshModelsContext) => Promise<readonly AnyModel[]>;

/**
 * As pi's coding-agent sets up the built-ins (model-runtime.ts): radius keeps its own discovery, OpenRouter's catalog is
 * narrowed to the key's models, every other provider gets the pi.dev overlay.
 */
export function catalogProvider(provider: Provider, generatedAt?: number, options: ModelCatalogOptions = {}): Provider {
	if (provider.id === "radius" || provider.refreshModels) return provider;
	if (provider.id === "openrouter") return withPersonalizedCatalog(provider, personalizeOpenRouterCatalog, generatedAt, options);
	return withModelCatalog(provider, generatedAt, options);
}

/**
 * pi's withPersonalizedCatalog: on each network refresh, built-ins plus a newer pi.dev catalog go through `personalize`,
 * and the result is saved and replaces the catalog, offline too. No freshness window or ETag; an empty saved list falls
 * back to the built-ins. It needs the credential, so it refreshes as other provider requests do.
 */
export function withPersonalizedCatalog(provider: Provider, personalize: PersonalizeCatalog, generatedAt?: number, options: ModelCatalogOptions = {}): Provider {
	let personal: readonly AnyModel[] = [];
	const builtins = () => provider.getAllModels?.() ?? provider.getModels();
	const all = () => personal.length > 0 ? personal : builtins();
	const now = options.now ?? Date.now;
	return {
		...provider,
		getModels: () => all().filter((model): model is Model<Api> => isModelType(model, "chat")),
		getAllModels: all,
		async refreshModels(context) {
			const restored = (context.stored?.models ?? []).filter((model) => model.provider === provider.id);
			if (!await context.publish({ update: () => { personal = restored; } })) return;
			if (!context.allowNetwork || context.signal.aborted) return;
			const response = await requestCatalog(provider.id, context.signal, options);
			let remote: readonly AnyModel[] = [];
			if (response.status !== 404 && response.status !== 501) {
				if (!response.ok) throw new Error(`Model catalog request failed for ${provider.id}: ${response.status}`);
				const lastModified = Date.parse(response.headers.get("last-modified") ?? "") || 0;
				const models = parseCatalog(provider.id, await response.json());
				if (generatedAt === undefined || lastModified > generatedAt) remote = models;
			}
			const personalized = await personalize(merge(builtins(), remote), context);
			if (context.signal.aborted) return;
			await context.publish({ persist: { models: personalized, checkedAt: now() }, update: () => { personal = personalized; } });
		},
	};
}

/** pi's withRemoteCatalog: a static provider's built-ins with a newer pi.dev catalog over them. */
export function withModelCatalog(provider: Provider, generatedAt?: number, options: ModelCatalogOptions = {}): Provider {
	if (provider.refreshModels) return provider;
	let overlay: readonly AnyModel[] = [];
	const all = () => merge(provider.getAllModels?.() ?? provider.getModels(), overlay);
	const now = options.now ?? Date.now;
	const newer = (entry: ModelsStoreEntry | undefined) => entry && (generatedAt === undefined || (entry.lastModified ?? 0) > generatedAt) ? entry.models : [];
	return {
		...provider,
		getModels: () => all().filter((model): model is Model<Api> => isModelType(model, "chat")),
		getAllModels: all,
		// The catalog is public: do not refresh a ChatGPT login just to read it.
		refreshModelsAuth: "configured",
		async refreshModels(context) {
			const stored = context.stored;
			if (!await context.publish({ update: () => { overlay = newer(stored); } })) return;
			if (!context.allowNetwork || context.signal.aborted) return;
			if (!context.force && stored?.checkedAt !== undefined && now() - stored.checkedAt < (options.intervalMs ?? MODEL_CATALOG_INTERVAL_MS)) return;
			const response = await requestCatalog(provider.id, context.signal, options, stored?.models.length ? stored.etag : undefined);
			if (response.status === 304 && stored) {
				await context.publish({ persist: { ...stored, checkedAt: now() } });
				return;
			}
			// No remote shard for this provider: keep its built-ins and avoid repeated requests.
			if (response.status === 404 || response.status === 501) {
				await context.publish({ persist: { ...(stored ?? { models: [] }), checkedAt: now() } });
				return;
			}
			if (!response.ok) throw new Error(`Model catalog request failed for ${provider.id}: ${response.status}`);
			const entry: ModelsStoreEntry = {
				models: parseCatalog(provider.id, await response.json()),
				lastModified: Date.parse(response.headers.get("last-modified") ?? "") || 0,
				checkedAt: now(),
				...(response.headers.get("etag") ? { etag: response.headers.get("etag")! } : {}),
			};
			await context.publish({ persist: entry, update: () => { overlay = newer(entry); } });
		},
	};
}

/** Same word-by-word matching as the phone; a list request without a query is strictly local. */
export function modelMatches(model: { provider: string; id: string; name: string }, query: string): boolean {
	const haystack = `${model.provider}/${model.id} ${model.name}`.toLowerCase();
	return query.toLowerCase().trim().split(/\s+/).every((word) => haystack.includes(word));
}

export class ModelCatalogs {
	readonly #models: MutableModels;
	readonly #options: ModelCatalogOptions;
	readonly #abort = new AbortController();
	#timer?: ReturnType<typeof setInterval>;
	#pending?: Promise<void>;
	#pendingForced = false;
	#lastMiss = -Infinity;

	constructor(models: MutableModels, options: ModelCatalogOptions = {}) {
		this.#models = models;
		this.#options = options;
	}

	/** Restore before the Harness resumes any runs; network work must not delay startup. */
	async restore(): Promise<void> {
		await this.#models.refresh({ allowNetwork: false, signal: this.#abort.signal });
	}

	start(): void {
		if (this.#timer || this.#abort.signal.aborted) return;
		void this.refresh();
		this.#timer = setInterval(() => { void this.refresh(true); }, this.#options.intervalMs ?? MODEL_CATALOG_INTERVAL_MS);
		this.#timer.unref();
	}

	refresh(force = false): Promise<void> {
		if (this.#abort.signal.aborted) return Promise.resolve();
		if (this.#pending) {
			// A normal startup check may only reuse a fresh cache. A miss must still get its forced check.
			return force && !this.#pendingForced ? this.#pending.then(() => this.refresh(true)) : this.#pending;
		}
		this.#pendingForced = force;
		const signal = AbortSignal.any([this.#abort.signal, AbortSignal.timeout(15_000)]);
		this.#pending = this.#models.refresh({ force, signal }).then((result) => {
			for (const [provider, error] of result.errors) this.#report(new Error(`Catalog ${provider}: ${error.message}`));
		}).catch((error) => { if (!signal.aborted) this.#report(error); }).finally(() => { this.#pending = undefined; });
		return this.#pending;
	}

	/**
	 * These providers' catalogs again, now, after any check under way: one whose account in use changed, as a catalog
	 * asked with the key may differ by key. Their own catalogs only; no four-hour window applies.
	 */
	async refreshProviders(ids: readonly string[]): Promise<void> {
		if (this.#abort.signal.aborted || ids.length === 0) return;
		await this.#pending;
		const signal = AbortSignal.any([this.#abort.signal, AbortSignal.timeout(15_000)]);
		try {
			const result = await this.#models.refresh({ providers: ids, force: true, signal });
			for (const [provider, error] of result.errors) this.#report(new Error(`Catalog ${provider}: ${error.message}`));
		} catch (error) {
			if (!signal.aborted) this.#report(error);
		}
	}

	async search(query?: string): Promise<void> {
		if (!query?.trim() || (await this.#models.getAvailable()).some((model) => modelMatches(model, query))) return;
		const now = (this.#options.now ?? Date.now)();
		// A typo, repeated keystrokes or many clients must not hammer every configured provider.
		if (now - this.#lastMiss < MISS_COOLDOWN_MS) {
			await this.#pending;
			return;
		}
		this.#lastMiss = now;
		await this.refresh(true);
	}

	async close(): Promise<void> {
		clearInterval(this.#timer);
		this.#abort.abort();
		await this.#pending;
	}

	#report(error: unknown): void {
		if (this.#options.onError) this.#options.onError(error);
		else console.error("[tau] model catalog refresh:", error);
	}
}
