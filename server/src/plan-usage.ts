// Subscription accounts' plan usage (docs/accounts.md "Usage sources"): asked of the provider every few minutes and on
// demand, and read from the headers of each answer of an account in use, which carry the 5-hour and weekly numbers.
import type { Api, Context as ModelContext, Model, Models, ModelsSimpleStreamOptions, OAuthCredential } from "@earendil-works/pi-ai";
import type { Accounts, StoredAccount } from "./accounts.ts";

export type UsageWindow = {
	/** Stable across the endpoint's answers and the headers': "5h", "week", "week-opus", "primary", ... */
	id: string;
	/** Short: "5h", "Week", "Opus". */
	label: string;
	/** 0 to 100. */
	usedPercent: number;
	/** When it starts again, ms. */
	resetsAt?: number;
	/** How long the window is. */
	seconds?: number;
};

export type Usage = {
	/** When the numbers were last had, ms. */
	at: number;
	windows: UsageWindow[];
	/** Credits or extra usage beyond the plan, as words: "$4.20 of $50 extra", "120 credits". */
	credits?: string;
	/** Why the last ask failed; the windows are the last ones had. */
	error?: string;
};

const HOUR = 3600;
const WEEK = 7 * 24 * HOUR;
const REFRESH_MARGIN_MS = 60_000;
/** An account's usage is asked at most this often, however many clients ask. */
const MIN_ASK_MS = 20_000;
/** How long to leave an endpoint that answered 429 alone when it does not say. */
const RATE_LIMIT_BACKOFF_MS = 10 * 60_000;

/** One of Claude's limits as its usage endpoint lists them (`limits`, November 2026). */
type ClaudeLimit = {
	kind?: string;
	group?: string;
	percent?: number | null;
	resets_at?: string | null;
	scope?: { model?: { display_name?: string | null } | null; surface?: { display_name?: string | null } | string | null } | null;
};

/**
 * A limit as a window: the session as "5h" and the whole week as "Week", as the older fields named them, and one
 * scoped to a model or a surface by its name ("Fable"), with the ids the older fields gave Opus and Sonnet.
 */
function claudeLimitWindow(limit: ClaudeLimit): UsageWindow[] {
	const seconds = limit.group === "session" ? 5 * HOUR : limit.group === "weekly" ? WEEK : undefined;
	if (seconds === undefined || typeof limit.percent !== "number") return [];
	const resetsAt = limit.resets_at ? Date.parse(limit.resets_at) : Number.NaN;
	const surface = limit.scope?.surface;
	const scope = limit.scope?.model?.display_name ?? (typeof surface === "string" ? surface : surface?.display_name) ?? undefined;
	let id: string;
	let label: string;
	if (scope === undefined || scope === null || scope === "") {
		id = seconds === WEEK ? "week" : "5h";
		label = seconds === WEEK ? "Week" : "5h";
	} else {
		const slug = scope.toLowerCase().replace(/[^a-z0-9]+/g, "-");
		id = seconds === WEEK ? `week-${slug}` : `5h-${slug}`;
		label = seconds === WEEK ? scope : `${scope} 5h`;
	}
	return [{ id, label, usedPercent: limit.percent, ...(Number.isFinite(resetsAt) ? { resetsAt } : {}), seconds }];
}

export type Fetcher = (credential: OAuthCredential, fetchImpl: typeof fetch) => Promise<Omit<Usage, "at">>;

const FETCHERS: Record<string, Fetcher> = {
	anthropic: async (credential, fetchImpl) => {
		const body = (await getJson(fetchImpl, "https://api.anthropic.com/api/oauth/usage", {
			authorization: `Bearer ${credential.access}`,
			"anthropic-beta": "oauth-2025-04-20",
		})) as Record<string, { utilization?: number | null; resets_at?: string | null } | null> & {
			extra_usage?: { is_enabled?: boolean; used_credits?: number; monthly_limit?: number } | null;
			limits?: ClaudeLimit[] | null;
		};
		const credits = body.extra_usage?.is_enabled ? `${dollars(body.extra_usage.used_credits)} of ${dollars(body.extra_usage.monthly_limit)} extra` : undefined;
		// The list of limits, where the endpoint has it: the ones a model or a surface has of its own, such as Fable's
		// week, are there only
		if (Array.isArray(body.limits) && body.limits.length > 0) {
			return { windows: body.limits.flatMap(claudeLimitWindow), ...(credits === undefined ? {} : { credits }) };
		}
		const windows: UsageWindow[] = [];
		for (const [key, id, label, seconds] of [
			["five_hour", "5h", "5h", 5 * HOUR],
			["seven_day", "week", "Week", WEEK],
			["seven_day_opus", "week-opus", "Opus", WEEK],
			["seven_day_sonnet", "week-sonnet", "Sonnet", WEEK],
		] as const) {
			const window = body[key];
			if (window?.utilization === undefined || window.utilization === null) continue;
			const resetsAt = window.resets_at ? Date.parse(window.resets_at) : Number.NaN;
			windows.push({ id, label, usedPercent: window.utilization, ...(Number.isFinite(resetsAt) ? { resetsAt } : {}), seconds });
		}
		return { windows, ...(credits === undefined ? {} : { credits }) };
	},
	"openai-codex": async (credential, fetchImpl) => {
		const accountId = typeof credential.accountId === "string" ? credential.accountId : undefined;
		const body = (await getJson(fetchImpl, "https://chatgpt.com/backend-api/wham/usage", {
			authorization: `Bearer ${credential.access}`,
			"user-agent": "codex-cli",
			...(accountId === undefined ? {} : { "chatgpt-account-id": accountId }),
		})) as {
			rate_limit?: CodexLimit;
			additional_rate_limits?: { limit_name?: string; rate_limit?: CodexLimit }[];
			credits?: { has_credits?: boolean; unlimited?: boolean; balance?: string };
		};
		const windows = codexWindows("", body.rate_limit);
		for (const extra of body.additional_rate_limits ?? []) windows.push(...codexWindows(extra.limit_name ?? "Other", extra.rate_limit));
		const credits = body.credits?.unlimited ? "Unlimited credits" : body.credits?.has_credits ? `${body.credits.balance ?? "0"} credits` : undefined;
		return { windows, ...(credits === undefined ? {} : { credits }) };
	},
};

type CodexWindow = { used_percent?: number; limit_window_seconds?: number; reset_at?: number };
type CodexLimit = { primary_window?: CodexWindow | null; secondary_window?: CodexWindow | null };

function codexWindows(name: string, limit: CodexLimit | undefined): UsageWindow[] {
	const windows: UsageWindow[] = [];
	for (const [key, which] of [
		["primary_window", "primary"],
		["secondary_window", "secondary"],
	] as const) {
		const window = limit?.[key];
		if (window?.used_percent === undefined) continue;
		const seconds = window.limit_window_seconds ?? (which === "primary" ? 5 * HOUR : WEEK);
		windows.push({
			id: name === "" ? which : `${name}:${which}`,
			label: name === "" ? windowLabel(seconds) : `${name} ${windowLabel(seconds)}`,
			usedPercent: window.used_percent,
			...(window.reset_at === undefined ? {} : { resetsAt: window.reset_at * 1000 }),
			seconds,
		});
	}
	return windows;
}

/** The windows an answer's headers carry, by provider. */
const HEADER_READERS: Record<string, (headers: Record<string, string>) => UsageWindow[]> = {
	anthropic: (headers) => {
		const windows: UsageWindow[] = [];
		for (const [key, id, label, seconds] of [
			["5h", "5h", "5h", 5 * HOUR],
			["7d", "week", "Week", WEEK],
		] as const) {
			const used = Number(headers[`anthropic-ratelimit-unified-${key}-utilization`]);
			if (headers[`anthropic-ratelimit-unified-${key}-utilization`] === undefined || !Number.isFinite(used)) continue;
			const reset = Number(headers[`anthropic-ratelimit-unified-${key}-reset`]);
			windows.push({ id, label, usedPercent: Math.round(used * 1000) / 10, ...(Number.isFinite(reset) && reset > 0 ? { resetsAt: reset * 1000 } : {}), seconds });
		}
		return windows;
	},
	"openai-codex": (headers) => {
		const windows: UsageWindow[] = [];
		for (const which of ["primary", "secondary"] as const) {
			const used = Number(headers[`x-codex-${which}-used-percent`]);
			if (headers[`x-codex-${which}-used-percent`] === undefined || !Number.isFinite(used)) continue;
			const minutes = Number(headers[`x-codex-${which}-window-minutes`]);
			const seconds = Number.isFinite(minutes) && minutes > 0 ? minutes * 60 : which === "primary" ? 5 * HOUR : WEEK;
			const reset = Number(headers[`x-codex-${which}-reset-at`]);
			windows.push({ id: which, label: windowLabel(seconds), usedPercent: used, ...(Number.isFinite(reset) && reset > 0 ? { resetsAt: reset * 1000 } : {}), seconds });
		}
		return windows;
	},
};

export class PlanUsage {
	readonly fetch: typeof fetch;
	readonly #accounts: Accounts;
	readonly #models: Models;
	readonly #pollMs: number;
	readonly #onChange: () => void;
	readonly #usage = new Map<string, Usage>();
	readonly #asking = new Map<string, Promise<void>>();
	/** When each account's usage was last asked, and until when its endpoint asked to be left alone (429). */
	readonly #askedAt = new Map<string, number>();
	readonly #quietUntil = new Map<string, number>();
	readonly #fetchers: Record<string, Fetcher>;
	readonly #minAskMs: number;
	#timer: ReturnType<typeof setInterval> | undefined;

	constructor(options: { accounts: Accounts; models: Models; fetch?: typeof fetch; pollMs?: number; minAskMs?: number; fetchers?: Record<string, Fetcher>; onChange: () => void }) {
		this.#minAskMs = options.minAskMs ?? MIN_ASK_MS;
		this.#fetchers = { ...FETCHERS, ...options.fetchers };
		this.#accounts = options.accounts;
		this.#models = options.models;
		this.fetch = options.fetch ?? fetch;
		this.#pollMs = options.pollMs ?? 5 * 60_000;
		this.#onChange = options.onChange;
	}

	start(): void {
		void this.refreshAll();
		this.#timer = setInterval(() => void this.refreshAll(), this.#pollMs);
		this.#timer.unref?.();
	}

	close(): void {
		if (this.#timer !== undefined) clearInterval(this.#timer);
	}

	of(accountId: string): Usage | undefined {
		return this.#usage.get(accountId);
	}

	async refreshAll(): Promise<void> {
		const ids = new Set(this.#accounts.all().map((account) => account.id));
		for (const id of this.#usage.keys()) if (!ids.has(id)) this.#usage.delete(id);
		await Promise.all(this.#accounts.all().filter((account) => this.#asksUsage(account)).map((account) => this.refresh(account.id)));
	}

	/**
	 * Asks the provider for the account's usage, once at a time, not again within 20 seconds, and not while its
	 * endpoint asked to be left alone.
	 */
	refresh(accountId: string): Promise<void> {
		const going = this.#asking.get(accountId);
		if (going !== undefined) return going;
		const now = Date.now();
		if (now - (this.#askedAt.get(accountId) ?? -Infinity) < this.#minAskMs || now < (this.#quietUntil.get(accountId) ?? 0)) return Promise.resolve();
		this.#askedAt.set(accountId, now);
		const asking = this.#ask(accountId).finally(() => this.#asking.delete(accountId));
		this.#asking.set(accountId, asking);
		return asking;
	}

	/** The usage an answer's headers carry, for the account in use when it was asked. */
	headers(accountId: string, provider: string, headers: Record<string, string>): void {
		const read = HEADER_READERS[provider];
		if (read === undefined) return;
		const lower = Object.fromEntries(Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]));
		const windows = read(lower);
		if (windows.length === 0) return;
		const before = this.#usage.get(accountId);
		const merged = [...(before?.windows ?? [])];
		let changed = before === undefined;
		for (const window of windows) {
			const index = merged.findIndex((each) => each.id === window.id);
			if (index < 0) {
				merged.push(window);
				changed = true;
			} else {
				const old = merged[index]!;
				if (old.usedPercent !== window.usedPercent || old.resetsAt !== window.resetsAt) changed = true;
				// The endpoint's label stays: it names the window as it names the others.
				merged[index] = { ...window, label: old.label };
			}
		}
		this.#usage.set(accountId, { ...before, at: Date.now(), windows: merged });
		if (changed) this.#onChange();
	}

	/** `models` whose answers' headers update the usage of the account they were asked with. */
	wrap(models: Models): Models {
		return new Proxy(models, {
			get: (target, property) => {
				if (property === "streamSimple") {
					return (model: Model<Api>, context: ModelContext, options?: ModelsSimpleStreamOptions) => {
						const accountId = HEADER_READERS[model.provider] === undefined ? undefined : this.#accounts.activeId(model.provider);
						if (accountId === undefined) return target.streamSimple(model, context, options);
						const given = options?.onResponse;
						return target.streamSimple(model, context, {
							...options,
							onResponse: async (response, responseModel) => {
								try {
									this.headers(accountId, model.provider, response.headers);
								} catch (error) {
									console.error("[tau] usage headers:", error);
								}
								await given?.(response, responseModel);
							},
						});
					};
				}
				const value = Reflect.get(target, property, target);
				return typeof value === "function" ? value.bind(target) : value;
			},
		});
	}

	async #ask(accountId: string): Promise<void> {
		const account = this.#accounts.all().find((each) => each.id === accountId);
		if (account === undefined || !this.#asksUsage(account)) return;
		const fetcher = this.#fetchers[account.provider]!;
		let result: Omit<Usage, "at"> | undefined;
		let error: string | undefined;
		try {
			let credential = await this.#fresh(account, false);
			try {
				result = await fetcher(credential, this.fetch);
			} catch (first) {
				if (!(first instanceof HttpError) || first.status !== 401) throw first;
				credential = await this.#fresh(account, true);
				result = await fetcher(credential, this.fetch);
			}
		} catch (caught) {
			if (caught instanceof HttpError && caught.status === 429) {
				// Asked too often (the endpoint's own limit, not the plan's): the numbers had stand, and the answers'
				// headers keep the account in use current meanwhile.
				this.#quietUntil.set(accountId, Date.now() + (caught.retryAfterMs ?? RATE_LIMIT_BACKOFF_MS));
				return;
			}
			error = (caught as Error).message ?? String(caught);
		}
		const before = this.#usage.get(accountId);
		if (result !== undefined) this.#usage.set(accountId, { at: Date.now(), ...result });
		else this.#usage.set(accountId, { at: before?.at ?? 0, windows: before?.windows ?? [], ...(before?.credits === undefined ? {} : { credits: before.credits }), error: error ?? "unknown" });
		this.#onChange();
	}

	#asksUsage(account: StoredAccount): boolean {
		return account.credential.type === "oauth" && this.#fetchers[account.provider] !== undefined;
	}

	/** The account's OAuth credential, refreshed when it is about to expire. */
	fresh(account: StoredAccount): Promise<OAuthCredential> {
		return this.#fresh(account, false);
	}

	/** The account's OAuth credential, refreshed when it is about to expire, or `force`d (the provider refused it). */
	async #fresh(account: StoredAccount, force: boolean): Promise<OAuthCredential> {
		const stale = (credential: OAuthCredential) => force || credential.expires < Date.now() + REFRESH_MARGIN_MS;
		if (!stale(account.credential as OAuthCredential)) return account.credential as OAuthCredential;
		const oauth = this.#models.getProvider(account.provider)?.auth.oauth;
		if (oauth === undefined) throw new Error(`${account.provider} has no OAuth`);
		const before = (account.credential as OAuthCredential).access;
		const credential = await this.#accounts.modifyAccount(account.id, async (current) => {
			if (current.type !== "oauth") return undefined;
			// Refreshed meanwhile, by a request or another ask.
			if (current.access !== before || !stale(current)) return undefined;
			return oauth.refresh(current, AbortSignal.timeout(30_000));
		});
		return credential as OAuthCredential;
	}
}

class HttpError extends Error {
	readonly status: number;
	readonly retryAfterMs: number | undefined;
	constructor(status: number, message: string, retryAfterMs?: number) {
		super(message);
		this.status = status;
		this.retryAfterMs = retryAfterMs;
	}
}

async function getJson(fetchImpl: typeof fetch, url: string, headers: Record<string, string>): Promise<unknown> {
	const response = await fetchImpl(url, { headers: { accept: "application/json", ...headers }, signal: AbortSignal.timeout(20_000) });
	if (!response.ok) {
		const text = await response.text().catch(() => "");
		const retryAfter = Number(response.headers.get("retry-after"));
		throw new HttpError(response.status, `${new URL(url).host} answered ${response.status}${text === "" ? "" : `: ${text.slice(0, 200)}`}`, Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : undefined);
	}
	return response.json();
}


function windowLabel(seconds: number): string {
	if (Math.abs(seconds - WEEK) < HOUR) return "Week";
	if (seconds % (24 * HOUR) === 0) return `${seconds / (24 * HOUR)}d`;
	return `${Math.round(seconds / HOUR)}h`;
}

function dollars(cents: number | undefined): string {
	return `$${((cents ?? 0) / 100).toFixed(2)}`;
}
