// A push relay (docs/notifications.md "Through a relay"): the account's APNs key stays with the relay
// (../relay, a Cloudflare Worker), and a server with the relay's token sends its pushes there instead of to Apple.
import type { ApnsEnvironment, ApnsPush, ApnsResult } from "./apns.ts";

const REQUEST_TIMEOUT_MS = 15_000;

export class PushRelay {
	readonly url: string;
	readonly #token: string;

	constructor(url: string, token: string) {
		this.url = url.replace(/\/+$/, "");
		this.#token = token;
	}

	/** Sends one push through the relay. Network failures reject; Apple's refusals resolve, as Apns.send's do. */
	async send(device: { token: string; environment: ApnsEnvironment }, push: ApnsPush): Promise<ApnsResult> {
		const response = await fetch(`${this.url}/push`, {
			method: "POST",
			headers: { authorization: `Bearer ${this.#token}`, "content-type": "application/json" },
			body: JSON.stringify({ token: device.token, environment: device.environment, ...push }),
			signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
		});
		const body = (await response.json().catch(() => ({}))) as { status?: number; reason?: string; error?: string; id?: string };
		// The relay's own refusal (a bad token, a topic not the app's): no Apple status to report.
		if (!response.ok || typeof body.status !== "number") throw new Error(`relay ${response.status}: ${body.error ?? ""} ${body.reason ?? ""}`.trim());
		return { status: body.status, ...(body.reason === undefined ? {} : { reason: body.reason }), ...(body.id === undefined ? {} : { id: body.id }) };
	}

	close(): void {}
}
