// The server's logins to model providers (docs/accounts.md): several accounts per provider, one in use, kept in a file of
// their own beside the database, owner-only; logins run here, their prompts answered from the clients; each
// subscription account's plan usage (src/plan-usage.ts).
//
// `Accounts` is the CredentialStore pi's Models reads: `read(provider)` is the account in use. Every write, a refresh
// pi makes inside `modify` included, goes through one queue, so a switch never lands between a refresh's read and its
// write.
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type {
	AuthEvent,
	AuthOperationOptions,
	AuthPrompt,
	Credential,
	CredentialInfo,
	CredentialStore,
	Models,
	OAuthCredential,
} from "@earendil-works/pi-ai";
import { type Fetcher, PlanUsage, type Usage } from "./plan-usage.ts";

export type StoredAccount = {
	id: string;
	provider: string;
	credential: Credential;
	addedAt: number;
	/** The user's name for it. */
	label?: string;
	email?: string;
	plan?: string;
	/** Its login no longer refreshes: why, until a refresh works again or it is signed in again. */
	problem?: string;
	/** When it was last put in use: signing out of the one in use goes back to the one before. */
	usedAt?: number;
};

type AccountsFile = { version: 1; accounts: StoredAccount[]; active: Record<string, string> };

/** An account as clients see it: no secrets. */
export type AccountInfo = {
	id: string;
	provider: string;
	providerName: string;
	type: Credential["type"];
	label?: string;
	email?: string;
	plan?: string;
	keyHint?: string;
	active: boolean;
	addedAt: number;
	problem?: string;
	usage?: Usage;
};

/** A provider the server has a key for from its environment (or files such as AWS profiles), not an account. */
export type Ambient = { provider: string; providerName: string; source: string };

export type LoginState = {
	id: string;
	provider: string;
	providerName: string;
	type: Credential["type"];
	startedAt: number;
	events: AuthEvent[];
	prompt?: { id: string } & DistributiveOmit<AuthPrompt, "signal">;
	done?: { accountId: string } | { error: string } | { cancelled: true };
};

export type ProviderInfo = { id: string; name: string; oauth?: { name: string; subscription: boolean }; apiKey?: { name: string } };

export type AccountsState = { accounts: AccountInfo[]; ambient: Ambient[]; logins: LoginState[]; providers: ProviderInfo[] };

type DistributiveOmit<T, K extends keyof never> = T extends unknown ? Omit<T, K> : never;

export class AccountError extends Error {
	readonly code: "not_found" | "bad_request";
	constructor(code: "not_found" | "bad_request", message: string) {
		super(message);
		this.code = code;
	}
}

/** How long a login waits for the user, and how long a finished one stays in the state for clients to show. */
const LOGIN_TIMEOUT_MS = 15 * 60_000;
const LOGIN_KEPT_MS = 2 * 60_000;
/** Providers that are not logins: tau's dev model. */
const HIDDEN_PROVIDERS = new Set(["dev"]);

/** The accounts file: `path`, or only in memory. */
export class Accounts implements CredentialStore {
	readonly path: string | undefined;
	#data: AccountsFile;
	#chain: Promise<unknown> = Promise.resolve();
	readonly #listeners = new Set<() => void>();

	constructor(path?: string) {
		this.path = path;
		this.#data = path === undefined ? empty() : load(path);
	}

	// CredentialStore, for pi's Models: the account in use of each provider.

	async read(providerId: string, options?: AuthOperationOptions): Promise<Credential | undefined> {
		options?.signal?.throwIfAborted();
		return this.#active(providerId)?.credential;
	}

	async list(options?: AuthOperationOptions): Promise<readonly CredentialInfo[]> {
		options?.signal?.throwIfAborted();
		return Object.keys(this.#data.active).flatMap((providerId) => {
			const account = this.#active(providerId);
			return account === undefined ? [] : [{ providerId, type: account.credential.type }];
		});
	}

	modify(providerId: string, fn: (current: Credential | undefined) => Promise<Credential | undefined>, options?: AuthOperationOptions): Promise<Credential | undefined> {
		return this.#queue(async () => {
			options?.signal?.throwIfAborted();
			const account = this.#active(providerId);
			if (account === undefined) {
				// pi's own login; tau adds accounts with `add`.
				const next = await fn(undefined);
				if (next !== undefined) this.#add(providerId, next, {});
				return next;
			}
			return this.#update(account, fn);
		});
	}

	delete(providerId: string, options?: AuthOperationOptions): Promise<void> {
		return this.#queue(async () => {
			options?.signal?.throwIfAborted();
			const account = this.#active(providerId);
			if (account !== undefined) this.#remove(account.id);
		});
	}

	// tau's own.

	/** Every account, in the order added. */
	all(): readonly StoredAccount[] {
		return this.#data.accounts;
	}

	activeId(providerId: string): string | undefined {
		return this.#active(providerId)?.id;
	}

	/** The account's credential after `fn`, as `modify` does for the one in use: a refresh of an account not in use. */
	modifyAccount(id: string, fn: (current: Credential) => Promise<Credential | undefined>): Promise<Credential> {
		return this.#queue(async () => {
			const account = this.#find(id);
			return (await this.#update(account, async (current) => (current === undefined ? undefined : fn(current)))) ?? account.credential;
		});
	}

	/** A new account, put in use. */
	add(provider: string, credential: Credential, info: { email?: string; plan?: string }): Promise<StoredAccount> {
		return this.#queue(async () => this.#add(provider, credential, info));
	}

	use(id: string): Promise<void> {
		return this.#queue(async () => {
			const account = this.#find(id);
			if (this.#data.active[account.provider] === id) return;
			this.#data.active[account.provider] = id;
			account.usedAt = Date.now();
			this.#save();
		});
	}

	rename(id: string, label: string): Promise<void> {
		return this.#queue(async () => {
			const account = this.#find(id);
			const trimmed = label.trim();
			if (trimmed === "") delete account.label;
			else account.label = trimmed.slice(0, 100);
			this.#save();
		});
	}

	remove(id: string): Promise<void> {
		return this.#queue(async () => {
			this.#find(id);
			this.#remove(id);
		});
	}

	/** Called after every change of the accounts, not of a credential's tokens. */
	onChange(listener: () => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	#active(providerId: string): StoredAccount | undefined {
		const id = this.#data.active[providerId];
		return id === undefined ? undefined : this.#data.accounts.find((account) => account.id === id);
	}

	#find(id: string): StoredAccount {
		const account = this.#data.accounts.find((each) => each.id === id);
		if (account === undefined) throw new AccountError("not_found", `No account ${id}`);
		return account;
	}

	#add(provider: string, credential: Credential, info: { email?: string; plan?: string }): StoredAccount {
		// The same account signed in to again: its new credential in place, its name and its place kept.
		const same = info.email === undefined ? undefined : this.#data.accounts.find((each) => each.provider === provider && each.credential.type === credential.type && each.email === info.email);
		if (same !== undefined) {
			same.credential = credential;
			delete same.problem;
			if (info.plan !== undefined) same.plan = info.plan;
			this.#data.active[provider] = same.id;
			same.usedAt = Date.now();
			this.#save();
			return same;
		}
		const account: StoredAccount = {
			id: randomUUID(),
			provider,
			credential,
			addedAt: Date.now(),
			usedAt: Date.now(),
			...(info.email === undefined ? {} : { email: info.email }),
			...(info.plan === undefined ? {} : { plan: info.plan }),
		};
		this.#data.accounts.push(account);
		this.#data.active[provider] = account.id;
		this.#save();
		return account;
	}

	#remove(id: string): void {
		const account = this.#find(id);
		this.#data.accounts = this.#data.accounts.filter((each) => each.id !== id);
		if (this.#data.active[account.provider] === id) {
			// Another of the provider's, the one in use before, as Telegram goes to another account on logging out of one.
			const next = this.#data.accounts.filter((each) => each.provider === account.provider).sort((a, b) => (a.usedAt ?? a.addedAt) - (b.usedAt ?? b.addedAt)).at(-1);
			if (next === undefined) delete this.#data.active[account.provider];
			else this.#data.active[account.provider] = next.id;
		}
		this.#save();
	}

	/** `fn` on the account's credential; a failure of an OAuth login's refresh is kept as its problem. */
	async #update(account: StoredAccount, fn: (current: Credential | undefined) => Promise<Credential | undefined>): Promise<Credential | undefined> {
		let next: Credential | undefined;
		try {
			next = await fn(account.credential);
		} catch (error) {
			if (account.credential.type === "oauth" && !isAbort(error)) {
				const problem = (error as Error).message ?? String(error);
				if (account.problem !== problem) {
					account.problem = problem;
					this.#save();
				}
			}
			throw error;
		}
		if (next === undefined) return account.credential;
		const changed = account.problem !== undefined;
		account.credential = next;
		delete account.problem;
		this.#save(changed);
		return next;
	}

	#save(notify = true): void {
		if (this.path !== undefined) {
			mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
			const temporary = `${this.path}.${process.pid}.tmp`;
			writeFileSync(temporary, `${JSON.stringify(this.#data, null, "\t")}\n`, { encoding: "utf-8", mode: 0o600 });
			renameSync(temporary, this.path);
		}
		if (notify) for (const listener of this.#listeners) listener();
	}

	#queue<T>(fn: () => Promise<T>): Promise<T> {
		const result = this.#chain.then(fn, fn);
		this.#chain = result.catch(() => {});
		return result;
	}
}

function empty(): AccountsFile {
	return { version: 1, accounts: [], active: {} };
}

function load(path: string): AccountsFile {
	if (!existsSync(path)) return empty();
	const data = JSON.parse(readFileSync(path, "utf-8")) as Partial<AccountsFile>;
	return { version: 1, accounts: data.accounts ?? [], active: data.active ?? {} };
}

function isAbort(error: unknown): boolean {
	return error instanceof Error && (error.name === "AbortError" || error.name === "TimeoutError");
}

type Pending = { promptId: string; resolve: (value: string) => void; reject: (error: Error) => void };

type Login = { state: LoginState; controller: AbortController; pending?: Pending; timer: ReturnType<typeof setTimeout>; cancelled?: boolean };

/** The accounts, their logins and usage, as clients see and change them. */
export class AccountsService {
	readonly accounts: Accounts;
	readonly usage: PlanUsage;
	readonly #models: Models;
	readonly #deviceId: () => string;
	readonly #logins = new Map<string, Login>();
	readonly #listeners = new Set<(state: AccountsState) => void>();
	#ambient: Ambient[] = [];
	#ambientDirty = true;
	#notifying: Promise<void> | undefined;
	#again = false;
	readonly #unsubscribe: () => void;

	readonly #identities: Record<string, (credential: Credential) => Promise<{ email?: string; plan?: string }>>;

	constructor(options: {
		accounts: Accounts;
		models: Models;
		deviceId: () => string;
		fetch?: typeof fetch;
		pollMs?: number;
		/** More providers' usage and who their accounts are: the dev server's (src/dev-accounts.ts). */
		usage?: Record<string, Fetcher>;
		identities?: Record<string, (credential: Credential) => Promise<{ email?: string; plan?: string }>>;
	}) {
		this.accounts = options.accounts;
		this.#identities = options.identities ?? {};
		this.#models = options.models;
		this.#deviceId = options.deviceId;
		this.usage = new PlanUsage({
			accounts: options.accounts,
			models: options.models,
			...(options.fetch === undefined ? {} : { fetch: options.fetch }),
			...(options.pollMs === undefined ? {} : { pollMs: options.pollMs }),
			...(options.usage === undefined ? {} : { fetchers: options.usage }),
			onChange: () => this.#changed(),
		});
		const stop = this.accounts.onChange(() => {
			this.#ambientDirty = true;
			this.#changed();
		});
		this.#unsubscribe = stop;
	}

	/** Starts asking for usage, now and every few minutes. */
	start(): void {
		this.usage.start();
	}

	close(): void {
		this.#unsubscribe();
		this.usage.close();
		for (const login of this.#logins.values()) {
			clearTimeout(login.timer);
			login.controller.abort(new Error("The server is stopping"));
		}
	}

	async state(): Promise<AccountsState> {
		if (this.#ambientDirty) {
			this.#ambientDirty = false;
			this.#ambient = await this.#findAmbient();
		}
		const name = (id: string) => this.#models.getProvider(id)?.name ?? id;
		const accounts = this.accounts.all().map((account): AccountInfo => {
			const usage = this.usage.of(account.id);
			return {
				id: account.id,
				provider: account.provider,
				providerName: name(account.provider),
				type: account.credential.type,
				...(account.label === undefined ? {} : { label: account.label }),
				...(account.email === undefined ? {} : { email: account.email }),
				...(account.plan === undefined ? {} : { plan: account.plan }),
				...(account.credential.type === "api_key" && account.credential.key !== undefined ? { keyHint: account.credential.key.slice(-4) } : {}),
				active: this.accounts.activeId(account.provider) === account.id,
				addedAt: account.addedAt,
				...(account.problem === undefined ? {} : { problem: account.problem }),
				...(usage === undefined ? {} : { usage }),
			};
		});
		return { accounts, ambient: this.#ambient, logins: [...this.#logins.values()].map((login) => login.state), providers: this.#providers() };
	}

	/** Called with the whole state after every change, no more often than the changes can be sent. */
	onChange(listener: (state: AccountsState) => void): () => void {
		this.#listeners.add(listener);
		return () => this.#listeners.delete(listener);
	}

	refresh(): Promise<void> {
		return this.usage.refreshAll();
	}

	login(providerId: string, type: Credential["type"]): string {
		const provider = this.#models.getProvider(providerId);
		if (provider === undefined || HIDDEN_PROVIDERS.has(providerId)) throw new AccountError("not_found", `No provider ${providerId}`);
		const method = type === "oauth" ? provider.auth.oauth : provider.auth.apiKey;
		if (method?.login === undefined) throw new AccountError("bad_request", `${provider.name} has no ${type === "oauth" ? "sign-in" : "API key"} login`);
		const id = randomUUID();
		const controller = new AbortController();
		const login: Login = {
			state: { id, provider: providerId, providerName: provider.name, type, startedAt: Date.now(), events: [] },
			controller,
			timer: setTimeout(() => controller.abort(new Error("The login timed out")), LOGIN_TIMEOUT_MS),
		};
		this.#logins.set(id, login);
		this.#changed();
		const interaction = {
			signal: controller.signal,
			notify: (event: AuthEvent) => {
				login.state.events.push(event);
				this.#changed();
			},
			prompt: (prompt: AuthPrompt) => this.#prompt(login, prompt),
		};
		const flow = (async (): Promise<Credential> => {
			if (type === "oauth") return provider.auth.oauth!.login({ ...interaction, signal: controller.signal }, { agentName: "tau", getDeviceId: this.#deviceId });
			return provider.auth.apiKey!.login!({ ...interaction, signal: controller.signal });
		})();
		void flow.then(
			async (credential) => {
				const own = this.#identities[providerId];
				const info = await (own === undefined ? identify(providerId, credential, this.usage.fetch) : own(credential)).catch(() => ({}));
				const account = await this.accounts.add(providerId, credential, info);
				this.#finish(login, { accountId: account.id });
				void this.usage.refresh(account.id);
			},
			(error: unknown) => this.#finish(login, login.cancelled ? { cancelled: true } : { error: (controller.signal.aborted ? (controller.signal.reason as Error)?.message : undefined) ?? (error as Error)?.message ?? String(error) }),
		);
		return id;
	}

	answer(loginId: string, promptId: string, value: string): void {
		const login = this.#logins.get(loginId);
		if (login === undefined) throw new AccountError("not_found", `No login ${loginId}`);
		const pending = login.pending;
		if (pending === undefined || pending.promptId !== promptId) throw new AccountError("bad_request", "That question is no longer asked");
		login.pending = undefined;
		delete login.state.prompt;
		this.#changed();
		pending.resolve(value);
	}

	cancel(loginId: string): void {
		const login = this.#logins.get(loginId);
		if (login === undefined) throw new AccountError("not_found", `No login ${loginId}`);
		if (login.state.done !== undefined) return;
		login.cancelled = true;
		login.controller.abort(new Error("Cancelled"));
	}

	#prompt(login: Login, prompt: AuthPrompt): Promise<string> {
		// A method that waits for a redirect to this machine's localhost cannot finish from a phone: the other one.
		if (prompt.type === "select") {
			const others = prompt.options.filter((option) => option.id !== "browser");
			if (others.length === 1 && others.length < prompt.options.length) return Promise.resolve(others[0]!.id);
		}
		const promptId = randomUUID();
		const { signal, ...shown } = prompt;
		return new Promise<string>((resolve, reject) => {
			const clear = (error: Error) => {
				if (login.pending?.promptId !== promptId) return;
				login.pending = undefined;
				delete login.state.prompt;
				this.#changed();
				reject(error);
			};
			login.pending = { promptId, resolve, reject };
			login.state.prompt = { id: promptId, ...shown };
			this.#changed();
			// The flow no longer needs it (a callback came first), or the login ended.
			signal?.addEventListener("abort", () => clear(new Error("The question was withdrawn")), { once: true });
			login.controller.signal.addEventListener("abort", () => clear(login.controller.signal.reason as Error), { once: true });
		});
	}

	#finish(login: Login, done: NonNullable<LoginState["done"]>): void {
		clearTimeout(login.timer);
		login.state.done = done;
		delete login.state.prompt;
		login.pending = undefined;
		this.#changed();
		setTimeout(() => {
			this.#logins.delete(login.state.id);
			this.#changed();
		}, LOGIN_KEPT_MS).unref?.();
	}

	#providers(): ProviderInfo[] {
		return this.#models.getProviders().flatMap((provider): ProviderInfo[] => {
			if (HIDDEN_PROVIDERS.has(provider.id)) return [];
			const oauth = provider.auth.oauth;
			const apiKey = provider.auth.apiKey;
			if (oauth === undefined && apiKey?.login === undefined) return [];
			return [
				{
					id: provider.id,
					name: provider.name,
					...(oauth === undefined ? {} : { oauth: { name: oauth.name, subscription: oauth.isSubscription === true } }),
					...(apiKey?.login === undefined ? {} : { apiKey: { name: apiKey.name } }),
				},
			];
		});
	}

	async #findAmbient(): Promise<Ambient[]> {
		const found: Ambient[] = [];
		for (const provider of this.#models.getProviders()) {
			if (HIDDEN_PROVIDERS.has(provider.id) || this.accounts.activeId(provider.id) !== undefined) continue;
			const check = await this.#models.checkAuth(provider.id).catch(() => undefined);
			if (check !== undefined) found.push({ provider: provider.id, providerName: provider.name, source: check.source ?? "environment" });
		}
		return found;
	}

	/** One state frame at a time; changes while one is made are sent in the next. */
	#changed(): void {
		if (this.#notifying !== undefined) {
			this.#again = true;
			return;
		}
		this.#notifying = (async () => {
			do {
				this.#again = false;
				const state = await this.state();
				for (const listener of this.#listeners) listener(state);
			} while (this.#again);
		})()
			.catch((error) => console.error("[tau] accounts state:", error))
			.finally(() => {
				this.#notifying = undefined;
				// A change between the loop's last check and here.
				if (this.#again) this.#changed();
			});
	}
}

/** Who the account is, as its provider says: an email and a plan, when it says. */
async function identify(provider: string, credential: Credential, fetchImpl: typeof fetch): Promise<{ email?: string; plan?: string }> {
	if (credential.type !== "oauth") return {};
	if (provider === "anthropic") {
		const response = await fetchImpl("https://api.anthropic.com/api/oauth/profile", {
			headers: { authorization: `Bearer ${credential.access}`, "anthropic-beta": "oauth-2025-04-20" },
			signal: AbortSignal.timeout(15_000),
		});
		if (!response.ok) return {};
		const body = (await response.json()) as { account?: { email?: string }; organization?: { organization_type?: string } };
		return { ...(body.account?.email === undefined ? {} : { email: body.account.email }), ...planName(body.organization?.organization_type?.replace(/^claude_/, "")) };
	}
	if (provider === "openai-codex") {
		const claims = jwtClaims((credential as OAuthCredential).access);
		const email = (claims["https://api.openai.com/profile"] as { email?: string } | undefined)?.email;
		const plan = (claims["https://api.openai.com/auth"] as { chatgpt_plan_type?: string } | undefined)?.chatgpt_plan_type;
		return { ...(email === undefined ? {} : { email }), ...planName(plan) };
	}
	if (provider === "github-copilot") {
		const response = await fetchImpl("https://api.github.com/user", {
			headers: { authorization: `token ${credential.refresh}`, accept: "application/vnd.github+json", "user-agent": "tau" },
			signal: AbortSignal.timeout(15_000),
		});
		if (!response.ok) return {};
		const body = (await response.json()) as { login?: string };
		return body.login === undefined ? {} : { email: body.login };
	}
	return {};
}

function planName(plan: string | undefined): { plan?: string } {
	if (plan === undefined || plan === "") return {};
	return { plan: plan.split("_").map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(" ") };
}

export function jwtClaims(token: string): Record<string, unknown> {
	try {
		return JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf-8")) as Record<string, unknown>;
	} catch {
		return {};
	}
}
