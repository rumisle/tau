import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import type { AuthEvent, AuthPrompt, Credential, ProviderAuthInteraction } from "@earendil-works/pi-ai";
import { Accounts, type AccountsState, shortProblem } from "../src/accounts.ts";
import { TauClient } from "../src/client.ts";
import { PlanUsage } from "../src/plan-usage.ts";
import { type Host, openHost } from "../src/host.ts";
import { type Server, serve } from "../src/server.ts";

/** A provider whose login asks what pi's do: a method (browser or device code), then shows a code and asks for one. */
function fakeProvider(refreshes: { fail?: string; count: number }) {
	let next = 0;
	return {
		id: "fake",
		name: "Fake",
		auth: {
			oauth: {
				name: "Fake (subscription)",
				isSubscription: true,
				async login(interaction: ProviderAuthInteraction) {
					const method = await interaction.prompt({ type: "select", message: "How?", options: [{ id: "browser", label: "Browser" }, { id: "device_code", label: "Device code" }] });
					assert.equal(method, "device_code");
					interaction.notify({ type: "device_code", userCode: "ABCD-1234", verificationUri: "https://example.com/device" });
					const code = await interaction.prompt({ type: "manual_code", message: "Paste the code", signal: interaction.signal });
					next += 1;
					return { type: "oauth" as const, access: `access-${code}-${next}`, refresh: `refresh-${next}`, expires: Date.now() + 3_600_000 };
				},
				async refresh(credential: Credential & { type: "oauth" }) {
					refreshes.count += 1;
					if (refreshes.fail !== undefined) throw new Error(refreshes.fail);
					return { ...credential, access: `${credential.access}-r`, expires: Date.now() + 3_600_000 };
				},
				async toAuth(credential: Credential & { type: "oauth" }) {
					return { apiKey: credential.access };
				},
			},
			apiKey: {
				name: "Fake API key",
				async login(interaction: ProviderAuthInteraction) {
					return { type: "api_key" as const, key: await interaction.prompt({ type: "secret", message: "Enter the key" }) };
				},
				async resolve(input: { credential?: { key?: string } }) {
					return input.credential?.key === undefined ? undefined : { auth: { apiKey: input.credential.key } };
				},
			},
		},
		getModels: () => [],
		stream: () => {
			throw new Error("no models");
		},
		streamSimple: () => {
			throw new Error("no models");
		},
	};
}

describe("accounts: a refresh's failure in a few words", () => {
	test("the provider's description, else the first line", () => {
		assert.equal(shortProblem('Anthropic token refresh request failed. details=Error: HTTP request failed. status=400; body={"error": "invalid_grant", "error_description": "Refresh token expired"}; stack=Error: x\n    at y'), "Refresh token expired");
		assert.equal(shortProblem("invalid_grant: refresh token revoked\n    at z"), "invalid_grant: refresh token revoked");
	});
});

describe("accounts: the file", () => {
	test("several per provider, one in use; removing it puts another in use; owner-only", async () => {
		const dir = mkdtempSync(join(tmpdir(), "tau-accounts-"));
		const path = join(dir, "tau.accounts.json");
		const accounts = new Accounts(path);
		const one = await accounts.add("anthropic", { type: "api_key", key: "sk-one" }, {});
		const two = await accounts.add("anthropic", { type: "api_key", key: "sk-two" }, { email: "b@example.com" });
		assert.deepEqual(await accounts.read("anthropic"), { type: "api_key", key: "sk-two" }, "the latest added is in use");
		await accounts.use(one.id);
		assert.deepEqual(await accounts.read("anthropic"), { type: "api_key", key: "sk-one" });
		await accounts.rename(one.id, "  Work  ");
		assert.equal(statSync(path).mode & 0o777, 0o600);
		const three = await accounts.add("anthropic", { type: "api_key", key: "sk-three" }, {});
		await accounts.remove(three.id);
		assert.equal(accounts.activeId("anthropic"), one.id, "signing out of the one in use goes back to the one in use before");
		const again = new Accounts(path);
		assert.equal(again.all().find((each) => each.id === one.id)?.label, "Work", "kept in the file");
		assert.equal(again.activeId("anthropic"), one.id);
		await again.remove(one.id);
		assert.equal(again.activeId("anthropic"), two.id);
		const signedInAgain = await again.add("anthropic", { type: "api_key", key: "sk-four" }, { email: "b@example.com" });
		assert.equal(signedInAgain.id, two.id, "the same account signed in to again replaces its credential");
		assert.deepEqual(await again.read("anthropic"), { type: "api_key", key: "sk-four" });
		assert.equal(again.all().length, 1);
		await again.remove(two.id);
		assert.equal(await again.read("anthropic"), undefined);
		assert.deepEqual(JSON.parse(readFileSync(path, "utf-8")).accounts, []);
	});
});

describe("accounts: logins, switching and usage over the protocol", () => {
	let host: Host;
	let server: Server;
	let client: TauClient;
	const refreshes: { fail?: string; count: number } = { count: 0 };
	const requests: string[] = [];
	let state: AccountsState;
	const waiters = new Set<() => void>();

	const until = (predicate: (state: AccountsState) => boolean, timeoutMs = 10_000): Promise<AccountsState> =>
		new Promise((resolve, reject) => {
			const check = () => {
				if (!predicate(state)) return;
				clearTimeout(timer);
				waiters.delete(check);
				resolve(state);
			};
			const timer = setTimeout(() => {
				waiters.delete(check);
				reject(new Error(`timed out: ${JSON.stringify(state)}`));
			}, timeoutMs);
			waiters.add(check);
			check();
		});

	before(async () => {
		const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
			const url = String(input);
			requests.push(`${url} ${new Headers(init?.headers).get("authorization")}`);
			if (url.endsWith("/api/oauth/usage")) {
				return Response.json({
					five_hour: { utilization: 16, resets_at: "2026-11-18T10:40:00.027430+00:00" },
					seven_day: { utilization: 41, resets_at: "2026-11-20T08:00:00+00:00" },
					seven_day_opus: null,
					extra_usage: { is_enabled: true, used_credits: 420, monthly_limit: 5000 },
				});
			}
			if (url.endsWith("/api/oauth/profile")) return Response.json({ account: { email: "me@example.com" }, organization: { organization_type: "claude_max", rate_limit_tier: "default_claude_max_20x" } });
			return new Response("no", { status: 404 });
		}) as typeof fetch;
		host = await openHost({ accounts: new Accounts(), accountsFetch: fetchImpl });
		host.models.setProvider(fakeProvider(refreshes) as never);
		server = await serve(host);
		client = await TauClient.connect(server.url);
		client.on((push) => {
			if (push.event !== "accounts") return;
			state = push.state as AccountsState;
			for (const waiter of [...waiters]) waiter();
		});
		state = await client.request<AccountsState>("accounts.subscribe", {});
	});
	after(async () => {
		await client.close();
		await server.close();
		await host.close();
	});

	test("the providers a login can be added for", () => {
		const fake = state.providers.find((provider) => provider.id === "fake");
		assert.deepEqual(fake, { id: "fake", name: "Fake", oauth: { name: "Fake (subscription)", subscription: true }, apiKey: { name: "Fake API key" } });
		assert.ok(!state.providers.some((provider) => provider.id === "dev"), "not the dev model");
	});

	test("a login: the browser method is passed over, the device code shown, the code asked; the account is in use", async () => {
		const { login } = await client.request<{ login: string }>("accounts.login", { provider: "fake", type: "oauth" });
		const asking = await until((each) => each.logins.some((one) => one.id === login && one.prompt !== undefined));
		const shown = asking.logins.find((one) => one.id === login)!;
		assert.deepEqual(shown.events, [{ type: "device_code", userCode: "ABCD-1234", verificationUri: "https://example.com/device" }] satisfies AuthEvent[]);
		assert.equal(shown.prompt?.type, "manual_code");
		assert.ok(!("signal" in shown.prompt!), "no signal in what clients see");
		await assert.rejects(client.request("accounts.answer", { login, prompt: "other", value: "x" }), /no longer asked/);
		await client.request("accounts.answer", { login, prompt: shown.prompt!.id, value: "c1" });
		const done = await until((each) => each.logins.some((one) => one.id === login && one.done !== undefined));
		const accountId = (done.logins.find((one) => one.id === login)!.done as { accountId: string }).accountId;
		const account = done.accounts.find((each) => each.id === accountId);
		assert.equal(account?.active, true);
		assert.equal(account?.type, "oauth");
		assert.equal((await host.models.getAuth("fake"))?.auth.apiKey, "access-c1-1");
		assert.equal(JSON.stringify(done).includes("refresh-1"), false, "no secrets in the state");
	});

	test("a second account is put in use; switching back is by hand, and requests use it at once", async () => {
		const { login } = await client.request<{ login: string }>("accounts.login", { provider: "fake", type: "oauth" });
		const asking = await until((each) => each.logins.some((one) => one.id === login && one.prompt !== undefined));
		await client.request("accounts.answer", { login, prompt: asking.logins.find((one) => one.id === login)!.prompt!.id, value: "c2" });
		const done = await until((each) => each.accounts.filter((account) => account.provider === "fake").length === 2);
		const [first, second] = done.accounts.filter((account) => account.provider === "fake");
		assert.equal(second?.active, true);
		assert.equal((await host.models.getAuth("fake"))?.auth.apiKey, "access-c2-2");
		await client.request("accounts.use", { id: first!.id });
		await until((each) => each.accounts.find((account) => account.id === first!.id)?.active === true);
		assert.equal((await host.models.getAuth("fake"))?.auth.apiKey, "access-c1-1");
		await client.request("accounts.rename", { id: first!.id, label: "Personal" });
		await until((each) => each.accounts.find((account) => account.id === first!.id)?.label === "Personal");
	});

	test("an API key: asked as a secret, shown by its last four characters", async () => {
		const { login } = await client.request<{ login: string }>("accounts.login", { provider: "fake", type: "api_key" });
		const asking = await until((each) => each.logins.some((one) => one.id === login && one.prompt?.type === "secret"));
		await client.request("accounts.answer", { login, prompt: asking.logins.find((one) => one.id === login)!.prompt!.id, value: "sk-fake-9876" });
		const done = await until((each) => each.accounts.some((account) => account.type === "api_key" && account.provider === "fake"));
		const account = done.accounts.find((each) => each.type === "api_key" && each.provider === "fake")!;
		assert.equal(account.keyHint, "9876");
		assert.equal(account.usage, undefined, "no usage for a key");
		await client.request("accounts.remove", { id: account.id });
		await until((each) => !each.accounts.some((one) => one.id === account.id));
	});

	test("a login cancelled ends as cancelled", async () => {
		const { login } = await client.request<{ login: string }>("accounts.login", { provider: "fake", type: "oauth" });
		await until((each) => each.logins.some((one) => one.id === login && one.prompt !== undefined));
		await client.request("accounts.cancel", { login });
		const done = await until((each) => each.logins.some((one) => one.id === login && one.done !== undefined));
		assert.deepEqual(done.logins.find((one) => one.id === login)!.done, { cancelled: true });
	});

	test("a login whose refresh fails says so on the account; a refresh that works clears it", async () => {
		const id = host.accounts.accounts.activeId("fake")!;
		await host.accounts.accounts.modifyAccount(id, async (current) => ({ ...current, expires: Date.now() - 1000 }) as Credential);
		refreshes.fail = "invalid_grant: refresh token revoked";
		await assert.rejects(host.models.getAuth("fake"));
		await until((each) => each.accounts.find((account) => account.id === id)?.problem?.includes("invalid_grant") === true);
		refreshes.fail = undefined;
		assert.match((await host.models.getAuth("fake"))?.auth.apiKey ?? "", /-r$/);
		await until((each) => each.accounts.find((account) => account.id === id)?.problem === undefined);
	});

	test("usage: asked of the provider, then updated by an answer's headers, the endpoint's labels kept", async () => {
		const account = await host.accounts.accounts.add("anthropic", { type: "oauth", access: "claude-access", refresh: "claude-refresh", expires: Date.now() + 3_600_000 }, { email: "me@example.com", plan: "Max" });
		await client.request("accounts.refresh", {});
		const asked = await until((each) => each.accounts.find((one) => one.id === account.id)?.usage !== undefined);
		const usage = asked.accounts.find((one) => one.id === account.id)!.usage!;
		assert.deepEqual(
			usage.windows.map(({ id, label, usedPercent, seconds }) => ({ id, label, usedPercent, seconds })),
			[
				{ id: "5h", label: "5h", usedPercent: 16, seconds: 18_000 },
				{ id: "week", label: "Week", usedPercent: 41, seconds: 604_800 },
			],
		);
		assert.equal(usage.windows[0]!.resetsAt, Date.parse("2026-11-18T10:40:00.027Z"));
		assert.equal(usage.credits, "$4.20 of $50.00 extra");
		assert.ok(requests.includes("https://api.anthropic.com/api/oauth/usage Bearer claude-access"));
		host.accounts.usage.headers(account.id, "anthropic", {
			"Anthropic-Ratelimit-Unified-5h-Utilization": "0.23",
			"anthropic-ratelimit-unified-5h-reset": "1794998400",
			"anthropic-ratelimit-unified-7d-utilization": "0.4",
			"anthropic-ratelimit-unified-7d-reset": "1795000000",
		});
		const updated = await until((each) => each.accounts.find((one) => one.id === account.id)?.usage?.windows[0]?.usedPercent === 23);
		const windows = updated.accounts.find((one) => one.id === account.id)!.usage!.windows;
		assert.equal(windows[0]!.resetsAt, 1_794_998_400_000);
		assert.equal(windows[1]!.usedPercent, 40);
	});

	test("an upgraded plan shows once the provider says so: the account's screen asks who it is", async () => {
		const account = await host.accounts.accounts.add("anthropic", { type: "oauth", access: "claude-upgraded", refresh: "claude-upgraded-refresh", expires: Date.now() + 3_600_000 }, { email: "upgraded@example.com", plan: "Pro" });
		await client.request("accounts.refresh", { id: account.id });
		await until((each) => each.accounts.find((one) => one.id === account.id)?.plan === "Ultra");
		assert.ok(requests.includes("https://api.anthropic.com/api/oauth/profile Bearer claude-upgraded"));
	});

	test("the headers come from the answers of the account in use", async () => {
		const id = host.accounts.accounts.activeId("anthropic")!;
		let seen: unknown;
		const target = {
			streamSimple: (_model: unknown, _context: unknown, options: { onResponse?: (response: { status: number; headers: Record<string, string> }, model: unknown) => Promise<void> }) => {
				void options.onResponse?.({ status: 200, headers: { "anthropic-ratelimit-unified-5h-utilization": "0.5" } }, undefined).then(() => (seen = "given"));
				return "events";
			},
		};
		const wrapped = host.accounts.usage.wrap(target as never);
		const events = wrapped.streamSimple({ provider: "anthropic", id: "claude" } as never, { messages: [] } as never, { onResponse: async () => {} } as never);
		assert.equal(events, "events");
		await until((each) => each.accounts.find((one) => one.id === id)?.usage?.windows.find((window) => window.id === "5h")?.usedPercent === 50);
		assert.equal(seen, "given", "the caller's onResponse still runs");
	});
});

describe("accounts: Claude's list of limits", () => {
	test("the session, the week and a model's own week, by its name; the older fields left aside", async () => {
		const accounts = new Accounts();
		const account = await accounts.add("anthropic", { type: "oauth", access: "a", refresh: "r", expires: Date.now() + 3_600_000 }, {});
		const usage = new PlanUsage({
			accounts,
			models: {} as never,
			minAskMs: 0,
			fetch: (async () =>
				Response.json({
					five_hour: { utilization: 63, resets_at: "2026-11-21T06:10:00Z" },
					seven_day: { utilization: 17, resets_at: "2026-11-24T15:00:00Z" },
					limits: [
						{ kind: "session", group: "session", percent: 63, resets_at: "2026-11-21T06:10:00Z", scope: null },
						{ kind: "weekly_all", group: "weekly", percent: 17, resets_at: "2026-11-24T15:00:00Z", scope: null },
						{ kind: "weekly_scoped", group: "weekly", percent: 4, resets_at: "2026-11-24T15:00:00Z", scope: { model: { id: null, display_name: "Fable" }, surface: null } },
					],
				})) as typeof fetch,
			onChange: () => {},
		});
		await usage.refresh(account.id);
		assert.deepEqual(
			usage.of(account.id)?.windows.map(({ id, label, usedPercent, seconds }) => ({ id, label, usedPercent, seconds })),
			[
				{ id: "5h", label: "5h", usedPercent: 63, seconds: 18_000 },
				{ id: "week", label: "Week", usedPercent: 17, seconds: 604_800 },
				{ id: "week-fable", label: "Fable", usedPercent: 4, seconds: 604_800 },
			],
		);
	});
});

describe("accounts: an API key's plan", () => {
	test("OpenCode Go: its rolling five hours, week and month, asked with the key", async () => {
		const accounts = new Accounts();
		const account = await accounts.add("opencode-go", { type: "api_key", key: "sk-go" }, {});
		const asked: string[] = [];
		const usage = new PlanUsage({
			accounts,
			models: {} as never,
			minAskMs: 0,
			fetch: (async (input: string | URL | Request, init?: RequestInit) => {
				asked.push(`${String(input)} ${new Headers(init?.headers).get("authorization")}`);
				return Response.json({
					usage: {
						rolling: { status: "ok", percent: 12, resetsAt: "2026-11-21T09:15:44.146Z" },
						weekly: { status: "ok", percent: 30, resetsAt: "2026-11-23T00:00:00.000Z" },
						monthly: { status: "rate-limited", percent: 100, resetsAt: "2026-12-18T09:08:26.000Z" },
					},
				});
			}) as typeof fetch,
			onChange: () => {},
		});
		await usage.refresh(account.id);
		assert.deepEqual(asked, ["https://opencode.ai/zen/go/v1/usage Bearer sk-go"]);
		assert.deepEqual(
			usage.of(account.id)?.windows.map(({ id, label, usedPercent, resetsAt }) => ({ id, label, usedPercent, resetsAt })),
			[
				{ id: "5h", label: "5h", usedPercent: 12, resetsAt: Date.parse("2026-11-21T09:15:44.146Z") },
				{ id: "week", label: "Week", usedPercent: 30, resetsAt: Date.parse("2026-11-23T00:00:00.000Z") },
				{ id: "month", label: "Month", usedPercent: 100, resetsAt: Date.parse("2026-12-18T09:08:26.000Z") },
			],
		);
	});
});

describe("accounts: a Mistral key's budgets", () => {
	test("Vibe's and the API's month, in percent", async () => {
		const accounts = new Accounts();
		const account = await accounts.add("mistral", { type: "api_key", key: "mk" }, {});
		const usage = new PlanUsage({
			accounts,
			models: {} as never,
			minAskMs: 0,
			fetch: (async (input: string | URL | Request) => {
				assert.equal(String(input), "https://api.mistral.ai/v1/billing/budget");
				return Response.json({
					vibe_budget: { usage_percentage: 40.5, initial_budget: 255, currency: "EUR", reset_at: "2026-12-01T00:00:00Z" },
					api_budget: { usage_percentage: 0, initial_budget: 25.5, currency: "EUR", reset_at: "2026-12-01T00:00:00Z" },
				});
			}) as typeof fetch,
			onChange: () => {},
		});
		await usage.refresh(account.id);
		assert.deepEqual(
			usage.of(account.id)?.windows.map(({ id, label, usedPercent }) => ({ id, label, usedPercent })),
			[
				{ id: "vibe", label: "Vibe", usedPercent: 40.5 },
				{ id: "api", label: "API", usedPercent: 0 },
			],
		);
	});
});

describe("accounts: an OpenRouter key's limits", () => {
	test("the key's limit and the account's credits, with what is left of them", async () => {
		const accounts = new Accounts();
		const account = await accounts.add("openrouter", { type: "api_key", key: "or" }, {});
		const usage = new PlanUsage({
			accounts,
			models: {} as never,
			minAskMs: 0,
			fetch: (async (input: string | URL | Request) => {
				const url = String(input);
				if (url.endsWith("/key")) {
					return Response.json({ data: { budgets: [{ scope: "key_limit", limit_usd: 12, spend_usd: 9, reset_interval: "weekly", resets_at: "2026-11-23T00:00:00Z" }] } });
				}
				return Response.json({ data: { total_credits: 100, total_usage: 95 } });
			}) as typeof fetch,
			onChange: () => {},
		});
		await usage.refresh(account.id);
		const shown = usage.of(account.id)!;
		assert.deepEqual(
			shown.windows.map(({ id, label, usedPercent, seconds }) => ({ id, label, usedPercent, seconds })),
			[
				{ id: "key_limit", label: "Key", usedPercent: 75, seconds: 604_800 },
				{ id: "credits", label: "Credits", usedPercent: 95, seconds: undefined },
			],
		);
		assert.equal(shown.credits, "$5.00 of $100.00 credits left");
	});
});

describe("accounts: usage asked too often", () => {
	test("a 429 keeps the numbers had, says nothing, and leaves the endpoint alone for its Retry-After", async () => {
		const accounts = new Accounts();
		const account = await accounts.add("anthropic", { type: "oauth", access: "a", refresh: "r", expires: Date.now() + 3_600_000 }, {});
		let answer: () => Response = () => Response.json({ five_hour: { utilization: 30, resets_at: "2026-11-18T10:40:00Z" } });
		let asked = 0;
		const usage = new PlanUsage({
			accounts,
			models: {} as never,
			minAskMs: 0,
			fetch: (async () => {
				asked += 1;
				return answer();
			}) as typeof fetch,
			onChange: () => {},
		});
		await usage.refresh(account.id);
		assert.equal(usage.of(account.id)?.windows[0]?.usedPercent, 30);
		answer = () => new Response("rate_limit_error", { status: 429, headers: { "retry-after": "60" } });
		await usage.refresh(account.id);
		assert.equal(usage.of(account.id)?.windows[0]?.usedPercent, 30, "the numbers had stand");
		assert.equal(usage.of(account.id)?.error, undefined, "not an error to show");
		await usage.refresh(account.id);
		assert.equal(asked, 2, "left alone after the 429");
	});
});
