// Credential store over pi's auth.json, so tau uses the same logins as the pi CLI.
// Every write is a locked read-modify-write with the same lock pi uses (proper-lockfile on the file itself), and
// OAuth refresh runs inside `modify`, so tau and a running pi never overwrite each other's rotated refresh tokens.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { AuthOperationOptions, Credential, CredentialInfo, CredentialStore } from "@earendil-works/pi-ai";
import lockfile from "proper-lockfile";

type AuthData = Record<string, Credential>;

export function defaultAuthPath(): string {
	const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
	return join(agentDir, "auth.json");
}

export class FileCredentialStore implements CredentialStore {
	readonly path: string;
	#chain: Promise<unknown> = Promise.resolve();

	constructor(path: string = defaultAuthPath()) {
		this.path = path;
	}

	async read(providerId: string, options?: AuthOperationOptions): Promise<Credential | undefined> {
		options?.signal?.throwIfAborted();
		const credential = this.#load()[providerId];
		if (credential?.type === "api_key" && credential.key?.startsWith("!")) {
			// Shell-command keys ("!op read ...") are a pi CLI feature; tau does not run them.
			return { ...credential, key: undefined };
		}
		return credential;
	}

	async list(options?: AuthOperationOptions): Promise<readonly CredentialInfo[]> {
		options?.signal?.throwIfAborted();
		return Object.entries(this.#load()).map(([providerId, credential]) => ({ providerId, type: credential.type }));
	}

	modify(
		providerId: string,
		fn: (current: Credential | undefined) => Promise<Credential | undefined>,
		options?: AuthOperationOptions,
	): Promise<Credential | undefined> {
		return this.#locked(async () => {
			const data = this.#load();
			const next = await fn(data[providerId]);
			if (next === undefined) return data[providerId];
			this.#save({ ...data, [providerId]: next });
			return next;
		}, options);
	}

	delete(providerId: string, options?: AuthOperationOptions): Promise<void> {
		return this.#locked(async () => {
			const data = this.#load();
			delete data[providerId];
			this.#save(data);
		}, options);
	}

	#load(): AuthData {
		if (!existsSync(this.path)) return {};
		const text = readFileSync(this.path, "utf-8").replace(/^\uFEFF/, "");
		return text.trim() === "" ? {} : (JSON.parse(text) as AuthData);
	}

	#save(data: AuthData): void {
		writeFileSync(this.path, JSON.stringify(data, null, 2), { encoding: "utf-8", mode: 0o600 });
	}

	/** In-process queue, then the cross-process file lock. */
	#locked<T>(fn: () => Promise<T>, options?: AuthOperationOptions): Promise<T> {
		const run = async (): Promise<T> => {
			options?.signal?.throwIfAborted();
			mkdirSync(dirname(this.path), { recursive: true });
			if (!existsSync(this.path)) writeFileSync(this.path, "{}", { encoding: "utf-8", mode: 0o600 });
			const release = await lockfile.lock(this.path, {
				realpath: false,
				stale: 30_000,
				retries: { retries: 50, factor: 1.5, minTimeout: 20, maxTimeout: 1_000 },
			});
			try {
				return await fn();
			} finally {
				await release().catch(() => {});
			}
		};
		const result = this.#chain.then(run, run);
		this.#chain = result.catch(() => {});
		return result;
	}
}
