// Providers from outside tau (docs/deploy.md "Providers from outside tau"): `--provider <file>`, an ES module (TypeScript
// as Node strips it) that exports a pi-ai `Provider` as `provider` and, optionally, how its API keys' usage is asked as
// `usage.apiKey`. Its default export is left alone, so the same file can be a pi extension too (pi calls the default
// export with its API; tau reads the named ones). The file imports pi-ai as anything does; those imports are the pi-ai
// this server runs, the same module instances, so the file needs no dependencies of its own and is tied to PI_REVISION
// as the rest of tau is. A file that fails to load is skipped with the reason: the server starts without it.
import { isAbsolute, resolve } from "node:path";
import { homedir } from "node:os";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
import type { Provider } from "@earendil-works/pi-ai";
import * as piAiCompat from "@earendil-works/pi-ai/compat";
import * as piAiModels from "@earendil-works/pi-ai/models";
import * as piAiOauth from "@earendil-works/pi-ai/oauth";

/** How an API key's usage is asked: what the provider tells the key's holder, as the protocol's windows. */
export type ApiKeyUsage = (key: string, context: { fetch: typeof fetch; signal: AbortSignal }) => Promise<unknown>;

export type ExternalProvider = { file: string; provider: Provider; usage: { apiKey?: ApiKeyUsage } };

/**
 * The modules a provider file may import, as pi's extension loader gives them (coding-agent's virtual-modules.ts): the
 * root as the compat entry, a superset of the core one, so a pi extension's imports resolve the same way here.
 */
const MODULES: Record<string, Record<string, unknown>> = {
	"@earendil-works/pi-ai": piAiCompat,
	"@earendil-works/pi-ai/compat": piAiCompat,
	"@earendil-works/pi-ai/models": piAiModels,
	"@earendil-works/pi-ai/oauth": piAiOauth,
};
for (const [name, module] of Object.entries({ ...MODULES })) MODULES[name.replace("@earendil-works/", "@mariozechner/")] = module;

const SCHEME = "tau-module:";
const GLOBAL = Symbol.for("tau.providerModules");
let hooked = false;

/** Resolves the modules above to this server's own, once: a module whose source re-exports the instance tau holds. */
function hookModules(): void {
	if (hooked) return;
	hooked = true;
	(globalThis as Record<symbol, unknown>)[GLOBAL] = MODULES;
	const identifier = /^[A-Za-z_$][\w$]*$/;
	registerHooks({
		resolve(specifier, context, nextResolve) {
			if (Object.hasOwn(MODULES, specifier)) return { url: `${SCHEME}${specifier}`, shortCircuit: true };
			return nextResolve(specifier, context);
		},
		load(url, context, nextLoad) {
			if (!url.startsWith(SCHEME)) return nextLoad(url, context);
			const name = url.slice(SCHEME.length);
			const names = Object.keys(MODULES[name]!).filter((key) => key !== "default" && identifier.test(key));
			const source = [
				`const m = globalThis[Symbol.for("tau.providerModules")][${JSON.stringify(name)}];`,
				names.length === 0 ? "" : `export const { ${names.join(", ")} } = m;`,
				"export default m.default ?? m;",
			].join("\n");
			return { format: "module", source, shortCircuit: true };
		},
	});
}

/** `~/x` and absolute paths; a relative one is from the server's working directory. */
export function providerPath(file: string): string {
	if (file === "~" || file.startsWith("~/")) return resolve(homedir(), file.slice(2));
	return isAbsolute(file) ? file : resolve(file);
}

/** The file's provider and usage, or an error saying why it cannot be used. */
export async function loadProviderFile(file: string): Promise<ExternalProvider> {
	hookModules();
	const path = providerPath(file);
	let module: Record<string, unknown>;
	try {
		module = (await import(pathToFileURL(path).href)) as Record<string, unknown>;
	} catch (error) {
		throw new Error(`it did not load: ${(error as Error).message ?? String(error)}`);
	}
	// Named exports; or, for a file written to the first draft of this, a default export object that has them.
	const fallback = typeof module.default === "object" && module.default !== null ? (module.default as Record<string, unknown>) : {};
	const provider = module.provider ?? fallback.provider;
	const usage = module.usage ?? fallback.usage;
	const problem = providerProblem(provider);
	if (problem !== undefined) throw new Error(problem);
	if (usage !== undefined && (typeof usage !== "object" || usage === null)) throw new Error("its usage export is not an object");
	const apiKey = (usage as { apiKey?: unknown } | undefined)?.apiKey;
	if (apiKey !== undefined && typeof apiKey !== "function") throw new Error("usage.apiKey is not a function");
	return { file: path, provider: provider as Provider, usage: apiKey === undefined ? {} : { apiKey: apiKey as ApiKeyUsage } };
}

/** What is wrong with a value meant as a pi-ai Provider, if anything. */
function providerProblem(value: unknown): string | undefined {
	if (typeof value !== "object" || value === null) return "it exports no provider (export const provider = createProvider({ ... }))";
	const provider = value as Partial<Provider>;
	if (typeof provider.id !== "string" || provider.id === "" || /[\s/]/.test(provider.id)) return "its provider has no id, or one with a space or a slash";
	if (typeof provider.name !== "string") return `provider ${provider.id} has no name`;
	if (typeof provider.getModels !== "function") return `provider ${provider.id} has no getModels`;
	const auth = provider.auth as Provider["auth"] | undefined;
	if (typeof auth !== "object" || auth === null || (auth.apiKey === undefined && auth.oauth === undefined)) return `provider ${provider.id} has no auth (apiKey or oauth)`;
	return undefined;
}

/**
 * Every file's provider whose id is not taken (by a built-in or a file before it), in order; the others skipped with a
 * log line each.
 */
export async function loadProviderFiles(files: readonly string[], taken: Iterable<string>, log: (line: string) => void = (line) => console.error(line)): Promise<{ loaded: ExternalProvider[]; skipped: { file: string; reason: string }[] }> {
	const ids = new Set(taken);
	const loaded: ExternalProvider[] = [];
	const skipped: { file: string; reason: string }[] = [];
	for (const file of files) {
		let external: ExternalProvider;
		try {
			external = await loadProviderFile(file);
		} catch (error) {
			const reason = (error as Error).message;
			skipped.push({ file, reason });
			log(`[tau] provider file ${file} skipped: ${reason}`);
			continue;
		}
		if (ids.has(external.provider.id)) {
			const reason = `provider ${external.provider.id} is already registered`;
			skipped.push({ file, reason });
			log(`[tau] provider file ${file} skipped: ${reason}`);
			continue;
		}
		ids.add(external.provider.id);
		loaded.push(external);
		log(`[tau] provider ${external.provider.id} from ${file}`);
	}
	return { loaded, skipped };
}
