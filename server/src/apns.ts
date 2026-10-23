// Apple's push service (docs/notifications.md): token-based authentication with the account's APNs key (a .p8 file,
// ES256), one HTTP/2 connection per environment, kept open and opened again when Apple or the network closes it.
// https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
import { createPrivateKey, type KeyObject, randomUUID, sign } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { type ClientHttp2Session, connect, constants } from "node:http2";
import { basename } from "node:path";

export type ApnsEnvironment = "development" | "production";

export type ApnsPush = {
	/** `alert`, `liveactivity`, or `background`. */
	type: "alert" | "liveactivity" | "background";
	/** The app's bundle ID, with `.push-type.liveactivity` for a Live Activity. */
	topic: string;
	/** 10: at once; 5: when it suits the device's power (the only one for background pushes). */
	priority: 10 | 5;
	payload: unknown;
	collapseId?: string;
	/** Epoch seconds after which Apple stops trying; 0: once, now. */
	expiration?: number;
};

export type ApnsResult = { status: number; reason?: string; id?: string };

/** Results that mean the device token is no longer the app's: forget it. */
export function isGone(result: ApnsResult): boolean {
	return result.status === 410 || (result.status === 400 && (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic"));
}

const ORIGINS: Record<ApnsEnvironment, string> = {
	development: "https://api.sandbox.push.apple.com",
	production: "https://api.push.apple.com",
};

/** Apple takes a token for up to an hour and refuses one renewed more often than every 20 minutes. */
const TOKEN_LIFETIME_MS = 50 * 60_000;
const REQUEST_TIMEOUT_MS = 15_000;

export type ApnsOptions = {
	/** The .p8 file, which only its owner may read. */
	keyPath: string;
	/** The key's ID: from the file name (AuthKey_<id>.p8) when not given. */
	keyId?: string;
	teamId: string;
	/** For tests: where each environment's requests go instead of Apple. */
	origins?: Partial<Record<ApnsEnvironment, string>>;
	now?: () => number;
};

export class Apns {
	readonly keyId: string;
	readonly teamId: string;
	readonly #key: KeyObject;
	readonly #origins: Record<ApnsEnvironment, string>;
	readonly #now: () => number;
	readonly #sessions = new Map<ApnsEnvironment, ClientHttp2Session>();
	#token?: { value: string; at: number };
	#closed = false;

	constructor(options: ApnsOptions) {
		if ((statSync(options.keyPath).mode & 0o077) !== 0) throw new Error(`${options.keyPath} is readable by others: chmod 600 ${options.keyPath}`);
		this.#key = createPrivateKey(readFileSync(options.keyPath, "utf8"));
		const fromName = /^AuthKey_([A-Z0-9]{10})\.p8$/.exec(basename(options.keyPath))?.[1];
		const keyId = options.keyId ?? fromName;
		if (keyId === undefined) throw new Error(`No APNs key ID: name the file AuthKey_<id>.p8 or give it`);
		this.keyId = keyId;
		this.teamId = options.teamId;
		this.#origins = { ...ORIGINS, ...options.origins };
		this.#now = options.now ?? Date.now;
	}

	/** The provider token: a JWT the key signs, renewed before Apple's hour is up. */
	token(): string {
		const now = this.#now();
		if (this.#token !== undefined && now - this.#token.at < TOKEN_LIFETIME_MS) return this.#token.value;
		const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
		const unsigned = `${encode({ alg: "ES256", kid: this.keyId })}.${encode({ iss: this.teamId, iat: Math.floor(now / 1000) })}`;
		const signature = sign("sha256", Buffer.from(unsigned), { key: this.#key, dsaEncoding: "ieee-p1363" }).toString("base64url");
		this.#token = { value: `${unsigned}.${signature}`, at: now };
		return this.#token.value;
	}

	/** Sends one push to one device. Network failures reject; Apple's refusals resolve with their status and reason. */
	async send(device: { token: string; environment: ApnsEnvironment }, push: ApnsPush): Promise<ApnsResult> {
		const result = await this.#request(device, push);
		// A token Apple thinks too old (a clock that jumped): a new one, once.
		if (result.status === 403 && result.reason === "ExpiredProviderToken") {
			this.#token = undefined;
			return this.#request(device, push);
		}
		return result;
	}

	close(): void {
		this.#closed = true;
		for (const session of this.#sessions.values()) session.close();
		this.#sessions.clear();
	}

	#session(environment: ApnsEnvironment): ClientHttp2Session {
		const current = this.#sessions.get(environment);
		if (current !== undefined && !current.closed && !current.destroyed) return current;
		const session = connect(this.#origins[environment]);
		const forget = () => {
			if (this.#sessions.get(environment) === session) this.#sessions.delete(environment);
		};
		session.on("goaway", forget);
		session.on("close", forget);
		session.on("error", forget);
		// Idle, it does not keep the process up.
		session.unref();
		this.#sessions.set(environment, session);
		return session;
	}

	#request(device: { token: string; environment: ApnsEnvironment }, push: ApnsPush): Promise<ApnsResult> {
		if (this.#closed) return Promise.reject(new Error("APNs closed"));
		const session = this.#session(device.environment);
		const body = JSON.stringify(push.payload);
		return new Promise((resolve, reject) => {
			const request = session.request({
				[constants.HTTP2_HEADER_METHOD]: "POST",
				[constants.HTTP2_HEADER_PATH]: `/3/device/${device.token}`,
				authorization: `bearer ${this.token()}`,
				"apns-push-type": push.type,
				"apns-topic": push.topic,
				"apns-priority": String(push.priority),
				"apns-id": randomUUID(),
				...(push.collapseId === undefined ? {} : { "apns-collapse-id": push.collapseId }),
				...(push.expiration === undefined ? {} : { "apns-expiration": String(push.expiration) }),
				"content-type": "application/json",
			});
			let status = 0;
			let id: string | undefined;
			let text = "";
			request.setTimeout(REQUEST_TIMEOUT_MS, () => request.close(constants.NGHTTP2_CANCEL));
			request.on("response", (headers) => {
				status = Number(headers[constants.HTTP2_HEADER_STATUS]);
				id = headers["apns-id"] as string | undefined;
			});
			request.setEncoding("utf8");
			request.on("data", (chunk: string) => (text += chunk));
			request.on("end", () => {
				if (status === 0) {
					reject(new Error("APNs closed the request"));
					return;
				}
				let reason: string | undefined;
				try {
					reason = text === "" ? undefined : (JSON.parse(text) as { reason?: string }).reason;
				} catch {
					reason = text;
				}
				resolve({ status, ...(reason === undefined ? {} : { reason }), ...(id === undefined ? {} : { id }) });
			});
			request.on("error", reject);
			request.end(body);
		});
	}
}

/** ActivityKit decodes a content state's dates as Swift does by default: seconds since 2001-01-01. */
export function activityDate(epochMs: number): number {
	return epochMs / 1000 - 978_307_200;
}
