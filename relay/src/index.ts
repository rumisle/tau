// tau's push relay (docs/push-relay.md): forwards a tau server's push to Apple with the account's APNs key, which only
// the relay holds. A server sends `POST /push` with its relay token; the answer is Apple's status and reason.
// What an answer says arrives sealed by the server with the phone's own key: the relay sees ciphertext.

export interface Env {
	/** The .p8 key's PEM. */
	APNS_KEY: string;
	APNS_KEY_ID: string;
	APNS_TEAM: string;
	/** The servers' tokens, one per line or comma (a name before a colon, for the log: `nest:abc…`). */
	RELAY_TOKENS: string;
	TOPIC: string;
}

type Push = {
	token: string;
	environment: "development" | "production";
	type: "alert" | "liveactivity" | "background";
	topic: string;
	priority: 10 | 5;
	payload: unknown;
	collapseId?: string;
	expiration?: number;
};

const ORIGINS = { development: "https://api.sandbox.push.apple.com", production: "https://api.push.apple.com" };
/** Apple takes a token for an hour and refuses one renewed more often than every 20 minutes. */
const TOKEN_LIFETIME_MS = 50 * 60_000;

// Per isolate: an isolate lives for many requests, so the JWT is reused as Apple wants.
let cached: { jwt: string; at: number; keyId: string } | undefined;

async function providerToken(env: Env): Promise<string> {
	const now = Date.now();
	if (cached !== undefined && cached.keyId === env.APNS_KEY_ID && now - cached.at < TOKEN_LIFETIME_MS) return cached.jwt;
	const pem = env.APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
	const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
	const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
	const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
	const unsigned = `${encode({ alg: "ES256", kid: env.APNS_KEY_ID })}.${encode({ iss: env.APNS_TEAM, iat: Math.floor(now / 1000) })}`;
	const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
	cached = { jwt: `${unsigned}.${base64url(new Uint8Array(signature))}`, at: now, keyId: env.APNS_KEY_ID };
	return cached.jwt;
}

function base64url(bytes: Uint8Array): string {
	let text = "";
	for (const byte of bytes) text += String.fromCharCode(byte);
	return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The server a token belongs to, by constant-time comparison; undefined for none. */
async function server(env: Env, header: string | null): Promise<string | undefined> {
	const given = header?.startsWith("Bearer ") ? header.slice(7).trim() : undefined;
	if (!given) return undefined;
	const digest = async (text: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
	const want = await digest(given);
	let found: string | undefined;
	for (const line of env.RELAY_TOKENS.split(/[\n,]/).map((s) => s.trim()).filter(Boolean)) {
		const colon = line.lastIndexOf(":");
		const [name, token] = colon > 0 ? [line.slice(0, colon), line.slice(colon + 1)] : ["server", line];
		const have = await digest(token);
		let diff = 0;
		for (let i = 0; i < have.length; i++) diff |= have[i]! ^ want[i]!;
		if (diff === 0) found = name;
	}
	return found;
}

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/" && request.method === "GET") return new Response("tau push relay\n");
		if (url.pathname !== "/push" || request.method !== "POST") return json({ error: "not_found" }, 404);
		const name = await server(env, request.headers.get("authorization"));
		if (name === undefined) return json({ error: "unauthorized" }, 401);
		let push: Push;
		try {
			push = (await request.json()) as Push;
		} catch {
			return json({ error: "bad_request", reason: "not JSON" }, 400);
		}
		if (typeof push.token !== "string" || !/^[0-9a-f]{32,200}$/i.test(push.token)) return json({ error: "bad_request", reason: "token" }, 400);
		if (push.environment !== "development" && push.environment !== "production") return json({ error: "bad_request", reason: "environment" }, 400);
		if (!["alert", "liveactivity", "background"].includes(push.type)) return json({ error: "bad_request", reason: "type" }, 400);
		if (push.topic !== env.TOPIC && push.topic !== `${env.TOPIC}.push-type.liveactivity`) return json({ error: "forbidden", reason: "topic" }, 403);
		const body = JSON.stringify(push.payload ?? {});
		if (body.length > 5120) return json({ error: "bad_request", reason: "payload too large" }, 400);

		const send = async () =>
			fetch(`${ORIGINS[push.environment]}/3/device/${push.token}`, {
				method: "POST",
				headers: {
					authorization: `bearer ${await providerToken(env)}`,
					"apns-push-type": push.type,
					"apns-topic": push.topic,
					"apns-priority": String(push.priority === 5 ? 5 : 10),
					"apns-id": crypto.randomUUID(),
					...(push.collapseId === undefined ? {} : { "apns-collapse-id": String(push.collapseId).slice(0, 64) }),
					...(push.expiration === undefined ? {} : { "apns-expiration": String(push.expiration) }),
					"content-type": "application/json",
				},
				body,
			});
		let response = await send();
		let text = await response.text();
		if (response.status === 403 && text.includes("ExpiredProviderToken")) {
			cached = undefined;
			response = await send();
			text = await response.text();
		}
		let reason: string | undefined;
		try {
			reason = text === "" ? undefined : (JSON.parse(text) as { reason?: string }).reason;
		} catch {
			reason = text.slice(0, 200);
		}
		console.log(`${name}: ${push.type} ${push.environment} -> ${response.status}${reason ? ` ${reason}` : ""}`);
		const id = response.headers.get("apns-id") ?? undefined;
		return json({ status: response.status, ...(reason === undefined ? {} : { reason }), ...(id === undefined ? {} : { id }) });
	},
};
