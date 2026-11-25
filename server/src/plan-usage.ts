// Subscription accounts' plan usage (docs/accounts.md "Usage sources"): asked of the provider every few minutes and on
// demand, and read from the headers of each answer of an account in use, which carry the 5-hour and weekly numbers.
import type { Api, Context as ModelContext, Model, Models, ModelsSimpleStreamOptions, OAuthCredential } from "@earendil-works/pi-ai";
import type { Accounts, StoredAccount } from "./accounts.ts";

export type UsageWindow = {
	/** Stable across the endpoint's answers and the headers': "5h", "week", "week-opus", "primary", ... */
	id: string;
	/** Short, for the list and the widget: "5h", "Week", "Opus". */
	label: string;
	/** Whole, for the account's page: "5-Hour Limit", "Opus Weekly Limit", "Credits". */
	title: string;
	/** What is spent or left in money, where the provider tells it: "$9.63 of $12.00 spent", "$2,383.76 spent". */
	amount?: string;
	/** 0 to 100; none for spend without a limit, which only its amount says. */
	usedPercent?: number;
	/** When it starts again, ms. */
	resetsAt?: number;
	/** How long the window is. */
	seconds?: number;
};

export type Usage = {
	/** When the numbers were last had, ms. */
	at: number;
	windows: UsageWindow[];
	/** Extra usage beyond the plan, as words: "$4.20 of $50.00 spent", "120 credits". */
	credits?: string;
	/** Why the last ask failed; the windows are the last ones had. */
	error?: string;
};

const HOUR = 3600;
const WEEK = 7 * 24 * HOUR;
const MONTH = 30 * 24 * HOUR;
const DAY = 24 * HOUR;
const REFRESH_MARGIN_MS = 60_000;
/** An account's usage is asked at most this often, however many clients ask. */
const MIN_ASK_MS = 20_000;
/** How long an API key's usage may take to answer, a provider file's or a built-in one's. */
const KEY_USAGE_TIMEOUT_MS = 30_000;
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
	let title: string;
	if (scope === undefined || scope === null || scope === "") {
		id = seconds === WEEK ? "week" : "5h";
		label = seconds === WEEK ? "Week" : "5h";
		title = limitTitle(seconds);
	} else {
		const slug = scope.toLowerCase().replace(/[^a-z0-9]+/g, "-");
		id = seconds === WEEK ? `week-${slug}` : `5h-${slug}`;
		label = seconds === WEEK ? scope : `${scope} 5h`;
		title = limitTitle(seconds, scope);
	}
	return [{ id, label, title, usedPercent: limit.percent, ...(Number.isFinite(resetsAt) ? { resetsAt } : {}), seconds }];
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
		const credits = body.extra_usage?.is_enabled ? `${dollars(body.extra_usage.used_credits)} of ${dollars(body.extra_usage.monthly_limit)} spent` : undefined;
		// The list of limits, where the endpoint has it: the ones a model or a surface has of its own, such as Fable's
		// week, are there only
		if (Array.isArray(body.limits) && body.limits.length > 0) {
			return { windows: body.limits.flatMap(claudeLimitWindow), ...(credits === undefined ? {} : { credits }) };
		}
		const windows: UsageWindow[] = [];
		for (const [key, id, label, seconds, scope] of [
			["five_hour", "5h", "5h", 5 * HOUR, undefined],
			["seven_day", "week", "Week", WEEK, undefined],
			["seven_day_opus", "week-opus", "Opus", WEEK, "Opus"],
			["seven_day_sonnet", "week-sonnet", "Sonnet", WEEK, "Sonnet"],
		] as const) {
			const window = body[key];
			if (window?.utilization === undefined || window.utilization === null) continue;
			const resetsAt = window.resets_at ? Date.parse(window.resets_at) : Number.NaN;
			windows.push({ id, label, title: limitTitle(seconds, scope), usedPercent: window.utilization, ...(Number.isFinite(resetsAt) ? { resetsAt } : {}), seconds });
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

/** Usage a provider tells an API key's holder: OpenCode Go's plan, Mistral's monthly budgets, OpenRouter's limits. */
export type KeyFetcher = (key: string, fetchImpl: typeof fetch, signal: AbortSignal) => Promise<Omit<Usage, "at">>;

const KEY_FETCHERS: Record<string, KeyFetcher> = {
	// The plan's rolling five hours, week and month, each a share of the month's dollars (opencode.ai/docs/console/go)
	"opencode-go": async (key, fetchImpl) => {
		const body = (await getJson(fetchImpl, "https://opencode.ai/zen/go/v1/usage", { authorization: `Bearer ${key}`, "user-agent": "tau" })) as {
			usage?: Record<string, { percent?: number; resetsAt?: string } | null>;
		};
		const windows: UsageWindow[] = [];
		for (const [key, id, label, seconds] of [
			["rolling", "5h", "5h", 5 * HOUR],
			["weekly", "week", "Week", WEEK],
			["monthly", "month", "Month", MONTH],
		] as const) {
			const window = body.usage?.[key];
			if (typeof window?.percent !== "number") continue;
			const resetsAt = window.resetsAt ? Date.parse(window.resetsAt) : Number.NaN;
			windows.push({ id, label, title: limitTitle(seconds), usedPercent: window.percent, ...(Number.isFinite(resetsAt) ? { resetsAt } : {}), seconds });
		}
		return { windows };
	},
	// The organization's two monthly budgets, as the Vibe CLI reads them (mistral-vibe's vibe/app_server/_billing.py):
	// Vibe's, which a plan's key draws on, and the API's, which a pay-as-you-go key does; usage_percentage is 0 to 100
	mistral: async (key, fetchImpl) => {
		type Budget = { usage_percentage?: number; initial_budget?: number; currency?: string; reset_at?: string | null } | null;
		const body = (await getJson(fetchImpl, "https://api.mistral.ai/v1/billing/budget", { authorization: `Bearer ${key}` })) as {
			vibe_budget?: Budget;
			api_budget?: Budget;
		};
		const windows: UsageWindow[] = [];
		for (const [budget, id, label] of [
			[body.vibe_budget, "vibe", "Vibe"],
			[body.api_budget, "api", "API"],
		] as const) {
			if (typeof budget?.usage_percentage !== "number") continue;
			const resetsAt = budget.reset_at ? Date.parse(budget.reset_at) : Number.NaN;
			const usedPercent = Math.max(0, budget.usage_percentage);
			const total = budget.initial_budget;
			windows.push({
				id,
				label,
				title: `${label} Monthly Budget`,
				usedPercent,
				...(typeof total === "number" && total > 0 ? { amount: `${money((total * usedPercent) / 100, budget.currency)} of ${money(total, budget.currency)} spent` } : {}),
				...(Number.isFinite(resetsAt) ? { resetsAt } : {}),
				seconds: MONTH,
			});
		}
		return { windows };
	},
	// The key's spending limits (its own, and guardrails over it), and the account's credits: what is left of them
	openrouter: async (key, fetchImpl) => {
		type Budget = { scope?: string; limit_usd?: number | null; spend_usd?: number; reset_interval?: string | null; resets_at?: string | null };
		const [info, credits] = await Promise.allSettled([
			getJson(fetchImpl, "https://openrouter.ai/api/v1/key", { authorization: `Bearer ${key}` }) as Promise<{ data?: { budgets?: Budget[] } }>,
			getJson(fetchImpl, "https://openrouter.ai/api/v1/credits", { authorization: `Bearer ${key}` }) as Promise<{ data?: { total_credits?: number; total_usage?: number } }>,
		]);
		if (info.status === "rejected") throw info.reason;
		const windows: UsageWindow[] = [];
		for (const budget of info.value.data?.budgets ?? []) {
			if (typeof budget.limit_usd !== "number" || budget.limit_usd <= 0 || typeof budget.spend_usd !== "number") continue;
			const resetsAt = budget.resets_at ? Date.parse(budget.resets_at) : Number.NaN;
			const seconds = { daily: DAY, weekly: WEEK, monthly: MONTH }[budget.reset_interval ?? ""];
			const label = budget.scope === "key_limit" ? "Key" : "Limit";
			windows.push({
				id: budget.scope ?? "limit",
				label,
				// "Key Limit", "Weekly Key Limit"; a guardrail's, "Spending Limit"
				title: `${seconds === undefined ? "" : `${spanName(seconds)} `}${label === "Key" ? "Key" : "Spending"} Limit`,
				usedPercent: (budget.spend_usd / budget.limit_usd) * 100,
				amount: `${money(budget.spend_usd)} of ${money(budget.limit_usd)} spent`,
				...(Number.isFinite(resetsAt) ? { resetsAt } : {}),
				...(seconds === undefined ? {} : { seconds }),
			});
		}
		const total = credits.status === "fulfilled" ? credits.value.data : undefined;
		if (typeof total?.total_credits !== "number" || total.total_credits <= 0) return { windows };
		const used = total.total_usage ?? 0;
		// The account's balance is not beyond a plan: it is all there is, so it is a window, with what is left
		windows.push({
			id: "credits",
			label: "Credits",
			title: "Credits",
			usedPercent: (used / total.total_credits) * 100,
			amount: `${money(Math.max(0, total.total_credits - used))} of ${money(total.total_credits)} left`,
		});
		return { windows };
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
			title: limitTitle(seconds, name === "" ? undefined : name),
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
			windows.push({ id, label, title: limitTitle(seconds), usedPercent: Math.round(used * 1000) / 10, ...(Number.isFinite(reset) && reset > 0 ? { resetsAt: reset * 1000 } : {}), seconds });
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
			windows.push({ id: which, label: windowLabel(seconds), title: limitTitle(seconds), usedPercent: used, ...(Number.isFinite(reset) && reset > 0 ? { resetsAt: reset * 1000 } : {}), seconds });
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
	readonly #keyFetchers: Record<string, KeyFetcher>;
	readonly #keyTimeoutMs: number;
	readonly #minAskMs: number;
	#timer: ReturnType<typeof setInterval> | undefined;

	constructor(options: { accounts: Accounts; models: Models; fetch?: typeof fetch; pollMs?: number; minAskMs?: number; fetchers?: Record<string, Fetcher>; keyFetchers?: Record<string, KeyFetcher>; keyTimeoutMs?: number; onChange: () => void }) {
		this.#minAskMs = options.minAskMs ?? MIN_ASK_MS;
		this.#fetchers = { ...FETCHERS, ...options.fetchers };
		this.#keyFetchers = { ...KEY_FETCHERS, ...options.keyFetchers };
		this.#keyTimeoutMs = options.keyTimeoutMs ?? KEY_USAGE_TIMEOUT_MS;
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
				// The endpoint's names stay: it names the window as it names the others.
				merged[index] = { ...window, label: old.label, title: old.title };
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
		let result: Omit<Usage, "at"> | undefined;
		let error: string | undefined;
		try {
			result = await this.#fetch(account);
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

	/** The account's usage from its provider: with its key, or its OAuth token, refreshed once if refused. */
	async #fetch(account: StoredAccount): Promise<Omit<Usage, "at">> {
		if (account.credential.type === "api_key") {
			// A provider file's fetcher as the built-ins: given a deadline, and what it answers checked
			const fetcher = this.#keyFetchers[account.provider]!;
			const abort = new AbortController();
			const timer = setTimeout(() => abort.abort(new Error(`its usage did not answer in ${Math.round(this.#keyTimeoutMs / 100) / 10} s`)), this.#keyTimeoutMs);
			try {
				const aborted = new Promise<never>((_, reject) => abort.signal.addEventListener("abort", () => reject(abort.signal.reason), { once: true }));
				return usageReport(await Promise.race([fetcher(account.credential.key ?? "", this.fetch, abort.signal), aborted]));
			} finally {
				clearTimeout(timer);
				abort.abort();
			}
		}
		const fetcher = this.#fetchers[account.provider]!;
		try {
			return await fetcher(await this.#fresh(account, false), this.fetch);
		} catch (first) {
			if (!(first instanceof HttpError) || first.status !== 401) throw first;
			return fetcher(await this.#fresh(account, true), this.fetch);
		}
	}

	#asksUsage(account: StoredAccount): boolean {
		if (account.credential.type === "api_key") return account.credential.key !== undefined && this.#keyFetchers[account.provider] !== undefined;
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

/**
 * A usage report as the protocol has it, from what a fetcher answered (a provider file's is plain JSON from outside):
 * the fields it knows, checked, a window's title its label when it has none; or an error naming what is wrong, which
 * the account shows as its usage's error.
 */
export function usageReport(value: unknown): Omit<Usage, "at"> {
	const fail = (what: string): never => {
		throw new Error(`malformed usage: ${what}`);
	};
	if (typeof value !== "object" || value === null) fail("not an object");
	const report = value as { windows?: unknown; credits?: unknown };
	if (!Array.isArray(report.windows)) fail("no windows list");
	if (report.credits !== undefined && typeof report.credits !== "string") fail("credits is not a string");
	const windows = (report.windows as unknown[]).map((each, index): UsageWindow => {
		const which = `window ${index + 1}`;
		if (typeof each !== "object" || each === null) fail(`${which} is not an object`);
		const window = each as Record<string, unknown>;
		const text = (key: string, required: boolean): string | undefined => {
			const field = window[key];
			if (field === undefined && !required) return undefined;
			if (typeof field !== "string" || field === "") fail(`${which} has no ${key}`);
			return field as string;
		};
		const number = (key: string): number | undefined => {
			const field = window[key];
			if (field === undefined) return undefined;
			if (typeof field !== "number" || !Number.isFinite(field) || field < 0) fail(`${which}'s ${key} is not a number of 0 or more`);
			return field as number;
		};
		const id = text("id", true)!;
		const label = text("label", true)!;
		const title = text("title", false) ?? label;
		const amount = text("amount", false);
		const usedPercent = number("usedPercent");
		const resetsAt = number("resetsAt");
		const seconds = number("seconds");
		if (usedPercent === undefined && amount === undefined) fail(`${which} has neither usedPercent nor amount`);
		return {
			id,
			label,
			title,
			...(usedPercent === undefined ? {} : { usedPercent }),
			...(amount === undefined ? {} : { amount }),
			...(resetsAt === undefined ? {} : { resetsAt }),
			...(seconds === undefined || seconds === 0 ? {} : { seconds }),
		};
	});
	return { windows, ...(report.credits === undefined ? {} : { credits: report.credits as string }) };
}

/** "5-Hour", "Daily", "Weekly", "Monthly", "3-Day". */
function spanName(seconds: number): string {
	if (Math.abs(seconds - WEEK) < HOUR) return "Weekly";
	if (Math.abs(seconds - DAY) < HOUR) return "Daily";
	if (Math.abs(seconds - MONTH) < DAY) return "Monthly";
	if (seconds % DAY === 0) return `${seconds / DAY}-Day`;
	return `${Math.round(seconds / HOUR)}-Hour`;
}

/** A plan limit's title: "5-Hour Limit", "Weekly Limit", "Opus Weekly Limit". */
function limitTitle(seconds: number, scope?: string): string {
	return `${scope === undefined ? "" : `${scope} `}${spanName(seconds)} Limit`;
}

/** "$9.63", "€255.00": an amount in its currency, US dollars when none is said. */
function money(amount: number, currency = "USD"): string {
	const symbol = ({ USD: "$", EUR: "€", GBP: "£" } as Record<string, string>)[currency.toUpperCase()];
	return symbol === undefined ? `${amount.toFixed(2)} ${currency.toUpperCase()}` : `${symbol}${amount.toFixed(2)}`;
}

function dollars(cents: number | undefined): string {
	return `$${((cents ?? 0) / 100).toFixed(2)}`;
}
