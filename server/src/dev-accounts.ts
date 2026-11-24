// For the app's tests (ios/TauUITests, with a dev server: `--dev-tps`): a provider whose sign-in shows a device code and
// completes on its own a few seconds later, as if the code were entered on the page, with plan usage as Claude's has;
// and an API key login. Each sign-in is a new account, dev1@example.com, dev2@...; no models.
import type { Credential, OAuthCredential, ProviderAuthInteraction } from "@earendil-works/pi-ai";
import type { Usage } from "./plan-usage.ts";

export const DEV_ACCOUNT_PROVIDER = "dev-account";

let signIns = 0;

export function devAccountProvider() {
	return {
		id: DEV_ACCOUNT_PROVIDER,
		name: "Dev Account",
		auth: {
			oauth: {
				name: "Dev (subscription)",
				isSubscription: true,
				async login(interaction: ProviderAuthInteraction): Promise<OAuthCredential> {
					interaction.notify({ type: "device_code", userCode: "DEVC-0DE1", verificationUri: "https://example.com/device", expiresInSeconds: 900 });
					await new Promise<void>((resolve, reject) => {
						const timer = setTimeout(resolve, 3_000);
						interaction.signal.addEventListener("abort", () => {
							clearTimeout(timer);
							reject(interaction.signal.reason);
						});
					});
					signIns += 1;
					return { type: "oauth", access: `dev-access-${signIns}`, refresh: `dev-refresh-${signIns}`, expires: Date.now() + 3_600_000, email: `dev${signIns}@example.com` };
				},
				async refresh(credential: OAuthCredential): Promise<OAuthCredential> {
					return { ...credential, expires: Date.now() + 3_600_000 };
				},
				async toAuth(credential: OAuthCredential) {
					return { apiKey: credential.access };
				},
			},
			apiKey: {
				name: "Dev API key",
				async login(interaction: ProviderAuthInteraction) {
					return { type: "api_key" as const, key: await interaction.prompt({ type: "secret", message: "Enter Dev API key" }) };
				},
				async resolve(input: { credential?: { key?: string } }) {
					return input.credential?.key === undefined ? undefined : { auth: { apiKey: input.credential.key } };
				},
			},
		},
		getModels: () => [],
		stream: () => {
			throw new Error("Dev Account has no models");
		},
		streamSimple: () => {
			throw new Error("Dev Account has no models");
		},
	};
}

/** 42% of the 5 hours, resetting in 2 h 14 min; 71% of the week, ahead of its pace, in 3 days; extra usage. */
export async function devAccountUsage(): Promise<Omit<Usage, "at">> {
	const now = Date.now();
	return {
		windows: [
			{ id: "5h", label: "5h", title: "5-Hour Limit", usedPercent: 42, resetsAt: now + (2 * 60 + 14) * 60_000, seconds: 5 * 3600 },
			{ id: "week", label: "Week", title: "Weekly Limit", usedPercent: 71, resetsAt: now + 3 * 86_400_000, seconds: 7 * 86_400 },
		],
		credits: "$4.20 of $50.00 spent",
	};
}

/** A key's, as OpenRouter's: a spending limit that does not reset, and the account's balance, both in money. */
export async function devAccountKeyUsage(): Promise<Omit<Usage, "at">> {
	return {
		windows: [
			{ id: "key_limit", label: "Key", title: "Key Limit", usedPercent: 80.2, amount: "$9.63 of $12.00 spent" },
			{ id: "credits", label: "Credits", title: "Credits", usedPercent: 95.4, amount: "$4.77 of $103.00 left" },
		],
	};
}

export async function devAccountIdentity(credential: Credential): Promise<{ email?: string; plan?: string }> {
	const email = (credential as { email?: unknown }).email;
	return { ...(typeof email === "string" ? { email } : {}), plan: "Max" };
}
