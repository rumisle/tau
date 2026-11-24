import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type AnyModel, type Provider } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { CatalogStore, catalogProvider, ModelCatalogs, MODEL_CATALOG_INTERVAL_MS, modelMatches, withModelCatalog, withPersonalizedCatalog } from "../src/model-catalog.ts";
import { devProvider } from "../src/dev-model.ts";
import { openHost } from "../src/host.ts";
import { serve } from "../src/server.ts";
import { TauClient } from "../src/client.ts";

const generatedAt = Date.parse("2026-01-01T00:00:00Z");
const modified = "Mon, 02 Feb 2026 00:00:00 GMT";
function provider(): Provider {
	const original = devProvider({}).provider;
	const models = original.getModels().map((model) => ({ ...model, provider: "catalog-test" }));
	return { ...original, id: "catalog-test", getModels: () => models, getAllModels: () => models };
}
function remote(id = "new-model"): AnyModel {
	return { ...provider().getModels()[0]!, id, name: id, type: "chat" };
}
function response(models: readonly AnyModel[] = [remote()]): Response {
	return Response.json(models, { headers: { "last-modified": modified, etag: '"v1"' } });
}
function setup(fetcher: typeof fetch, options: { store?: CatalogStore; now?: () => number; intervalMs?: number } = {}) {
	const models = createModels({ modelsStore: options.store ?? new CatalogStore() });
	models.setProvider(withModelCatalog(provider(), generatedAt, { fetch: fetcher, ...options }));
	return models;
}

test("a remote overlay adds models, overrides metadata, and retains missing built-ins and model types", async () => {
	const baseline = provider().getModels()[0]!;
	const image = { ...remote("image"), type: "image" } as unknown as AnyModel;
	const models = setup(async () => response([remote(), { ...baseline, name: "Updated" }, image]));
	await models.refresh();
	assert.equal(models.getModel("catalog-test", "new-model")?.name, "new-model");
	assert.equal(models.getModel("catalog-test", baseline.id)?.name, "Updated");
	assert.ok(models.getModel("catalog-test", "parrot"));
	assert.ok(models.getModelOfType("image", "catalog-test", "image"));
	assert.equal(models.getModelsOfType("chat").some((model) => model.id === "image"), false);
});

test("restore uses the persisted cache without network, and file permissions are owner-only", async () => {
	const dir = mkdtempSync(join(tmpdir(), "tau-catalog-"));
	try {
		const directory = join(dir, "models");
		const models = setup(async () => response(), { store: new CatalogStore(directory) });
		await models.refresh();
		const restored = setup(async () => { throw new Error("must not fetch"); }, { store: new CatalogStore(directory) });
		await restored.refresh({ allowNetwork: false });
		assert.ok(restored.getModel("catalog-test", "new-model"));
		assert.equal(statSync(directory).mode & 0o777, 0o700);
		assert.equal(statSync(join(directory, readdirSync(directory)[0]!)).mode & 0o777, 0o600);
	} finally { rmSync(dir, { recursive: true, force: true }); }
});

test("a new build ignores older cached metadata", async () => {
	const store = new CatalogStore();
	await store.write("catalog-test", { models: [remote()], lastModified: generatedAt - 1 });
	const models = setup(async () => response(), { store });
	await models.refresh({ allowNetwork: false });
	assert.equal(models.getModel("catalog-test", "new-model"), undefined);
});

test("four-hour freshness skips network, expired catalogs revalidate with ETag, force bypasses freshness", async () => {
	let now = 100;
	let calls = 0;
	const models = setup(async (_url, init) => {
		calls++;
		if (calls === 1) return response();
		assert.equal(new Headers(init?.headers).get("if-none-match"), '"v1"');
		return new Response(null, { status: 304 });
	}, { now: () => now });
	await models.refresh();
	await models.refresh();
	assert.equal(calls, 1);
	now += MODEL_CATALOG_INTERVAL_MS;
	await models.refresh();
	assert.equal(calls, 2);
	assert.ok(models.getModel("catalog-test", "new-model"));
	await models.refresh({ force: true });
	assert.equal(calls, 3);
});

test("network errors and malformed catalogs leave the last good overlay and cache intact", async () => {
	let mode = 0;
	const store = new CatalogStore();
	const models = setup(async () => {
		if (mode === 1) throw new Error("offline");
		if (mode === 2) return Response.json({ unexpected: "bad data" });
		if (mode === 3) return new Response("unavailable", { status: 503 });
		return response();
	}, { store });
	await models.refresh();
	const before = await store.read("catalog-test");
	for (mode = 1; mode <= 3; mode++) {
		const result = await models.refresh({ force: true });
		assert.equal(result.errors.size, 1);
		assert.ok(models.getModel("catalog-test", "new-model"));
		assert.deepEqual(await store.read("catalog-test"), before);
	}
});

test("missing remote shards retain built-ins and are cached; native discovery is not replaced", async () => {
	let calls = 0;
	const models = setup(async () => { calls++; return new Response(null, { status: 404 }); });
	await models.refresh();
	await models.refresh();
	assert.equal(calls, 1);
	assert.equal(models.getModelsOfType("chat").length, 2);
	const dynamic = { ...provider(), refreshModels: async () => {} };
	assert.equal(withModelCatalog(dynamic), dynamic);
});

test("public catalog discovery does not refresh an expired OAuth credential", async () => {
	const models = createModels();
	let refreshes = 0;
	const original = provider();
	const oauth = {
		name: "Test",
		login: async () => ({ type: "oauth" as const, access: "token", refresh: "refresh", expires: 0 }),
		refresh: async () => { refreshes++; throw new Error("expired login"); },
		toAuth: async () => ({ apiKey: "token" }),
	};
	models.setProvider(withModelCatalog({ ...original, auth: { oauth } }, generatedAt, { fetch: async () => response() }));
	await models.login("catalog-test", "oauth", { prompt: async () => "", notify: () => {} });
	await models.refresh();
	assert.equal(refreshes, 0);
	assert.ok(models.getModel("catalog-test", "new-model"));
});

test("startup is background, interval refreshes, concurrent refreshes coalesce, and close stops the timer", async (t) => {
	t.mock.timers.enable({ apis: ["setInterval"] });
	let calls = 0;
	let now = 0;
	const models = setup(async () => { calls++; return response(); }, { now: () => now, intervalMs: 100 });
	const catalogs = new ModelCatalogs(models, { now: () => now, intervalMs: 100 });
	await catalogs.restore();
	assert.equal(calls, 0);
	catalogs.start();
	assert.equal(calls, 0, "start does not wait for a network request");
	await Promise.all([catalogs.refresh(), catalogs.refresh()]);
	assert.equal(calls, 1);
	now += 100;
	t.mock.timers.tick(100);
	await catalogs.refresh();
	assert.equal(calls, 2);
	await catalogs.close();
	now += 100;
	t.mock.timers.tick(100);
	await catalogs.refresh();
	assert.equal(calls, 2);
});

test("only a nonempty search miss refreshes, and repeated misses are bounded across queries", async () => {
	let now = 0;
	let calls = 0;
	const models = setup(async () => { calls++; return response(); });
	const catalogs = new ModelCatalogs(models, { now: () => now });
	try {
		await catalogs.search();
		await catalogs.search(" ");
		await catalogs.search("echo");
		assert.equal(calls, 0);
		await catalogs.search("new-model");
		assert.equal(calls, 1);
		await catalogs.search("new-model");
		await catalogs.search("typo");
		assert.equal(calls, 1);
		now += 60_000;
		await catalogs.search("another-model");
		assert.equal(calls, 2);
	} finally { await catalogs.close(); }
});

test("a miss during a cache-only startup check still forces one network check", async () => {
	let calls = 0;
	const store = new CatalogStore();
	await store.write("catalog-test", { models: [], checkedAt: Date.now(), lastModified: generatedAt + 1 });
	const models = setup(async () => { calls++; return response(); }, { store });
	const catalogs = new ModelCatalogs(models);
	try {
		const startup = catalogs.refresh();
		await Promise.all([startup, catalogs.search("new-model")]);
		assert.equal(calls, 1);
		assert.ok(models.getModel("catalog-test", "new-model"));
	} finally { await catalogs.close(); }
});

test("simultaneous missing searches share one result instead of returning a stale list", async () => {
	const started = Promise.withResolvers<void>();
	const release = Promise.withResolvers<void>();
	let calls = 0;
	const models = setup(async () => {
		calls++;
		started.resolve();
		await release.promise;
		return response();
	});
	const catalogs = new ModelCatalogs(models);
	try {
		const first = catalogs.search("new-model");
		await started.promise;
		let secondFinished = false;
		const second = catalogs.search("new-model").then(() => { secondFinished = true; });
		await Promise.resolve();
		assert.equal(secondFinished, false);
		release.resolve();
		await Promise.all([first, second]);
		assert.equal(calls, 1);
		assert.ok(models.getModel("catalog-test", "new-model"));
	} finally { release.resolve(); await catalogs.close(); }
});

test("close aborts an in-flight catalog request", async () => {
	const started = Promise.withResolvers<void>();
	let signal: AbortSignal | undefined;
	const models = setup(async (_url, init) => {
		signal = init!.signal!;
		started.resolve();
		return new Promise<Response>((_resolve, reject) => signal!.addEventListener("abort", () => reject(signal!.reason), { once: true }));
	});
	const catalogs = new ModelCatalogs(models);
	catalogs.start();
	await started.promise;
	await catalogs.close();
	assert.equal(signal?.aborted, true);
});

test("providers are wrapped as pi wraps them: radius alone, OpenRouter personalized, the rest overlaid", async () => {
	const base = provider();
	const radius = { ...base, id: "radius" };
	assert.equal(catalogProvider(radius), radius);
	const openrouter = catalogProvider({ ...base, id: "openrouter" });
	assert.equal(openrouter.refreshModelsAuth, undefined, "OpenRouter needs the key to personalize");
	assert.equal(catalogProvider(base).refreshModelsAuth, "configured");
});

test("a personalized catalog replaces the list with what personalize keeps, offline too, built-ins when empty", async () => {
	let calls = 0;
	const store = new CatalogStore();
	const make = (fetcher: typeof fetch) => {
		const models = createModels({ modelsStore: store });
		models.setProvider(withPersonalizedCatalog(provider(), async (catalog) => catalog.filter((model) => model.id !== "echo"), generatedAt, { fetch: fetcher }));
		return models;
	};
	const models = make(async () => { calls++; return response(); });
	assert.ok(models.getModel("catalog-test", "echo"), "built-ins before any refresh");
	await models.refresh();
	await models.refresh();
	assert.equal(calls, 2, "no freshness window, as pi");
	assert.equal(models.getModel("catalog-test", "echo"), undefined);
	assert.ok(models.getModel("catalog-test", "new-model"));
	const offline = make(async () => { throw new Error("must not fetch"); });
	await offline.refresh({ allowNetwork: false });
	assert.equal(offline.getModel("catalog-test", "echo"), undefined);
	assert.ok(offline.getModel("catalog-test", "new-model"));
	const missing = make(async () => new Response(null, { status: 404 }));
	await missing.refresh();
	assert.ok(missing.getModel("catalog-test", "parrot"), "no remote shard: personalize the built-ins");
});

test("model matching is case-insensitive, word-by-word, and accepts provider/id", () => {
	const model = { provider: "openai", id: "gpt-6.2-sol", name: "GPT-6.2 Sol" };
	assert.ok(modelMatches(model, "OPENAI 6.2 sol"));
	assert.ok(modelMatches(model, "openai/gpt-6.2-sol"));
	assert.equal(modelMatches(model, "6.2 terra"), false);
});

test("models.list stays local; query misses refresh and return a new selectable model", async () => {
	let calls = 0;
	const host = await openHost({ cwd: tmpdir(), modelCatalog: false });
	for (const existing of host.models.getProviders()) host.models.deleteProvider(existing.id);
	host.models.setProvider(withModelCatalog(provider(), generatedAt, { fetch: async () => { calls++; return response(); } }));
	const server = await serve(host);
	const client = await TauClient.connect(server.url);
	try {
		await client.request("models.list", {});
		assert.equal(calls, 0);
		await client.request("models.list", { query: "echo" });
		assert.equal(calls, 0);
		const result = await client.request("models.list", { query: "new-model" });
		assert.equal(calls, 1);
		assert.ok(result.models.some((model: { id: string }) => model.id === "new-model"));
		await client.request("models.list", {});
		assert.equal(calls, 1);
		await assert.rejects(client.request("models.list", { query: "x".repeat(201) }));
	} finally { await client.close(); await server.close(); await host.close(); }
});
