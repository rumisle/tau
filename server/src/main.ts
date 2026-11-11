// tau server: `node src/main.ts [--data dir | --db path | --memory] [--port n] [--host addr] [--model provider/id] [--cwd dir]
//   (--cwd: where chats start instead of the home directory, for tests)
//   [--dev-tps n] [--dev-cache-ttl s]` (speed of the dev/echo model, tokens per second; a prompt cache lifetime that makes it
//   charge as a costly model, to try cache warming)
//   [--token-file path] [--no-auth] [--apns-key path --apns-team id [--apns-key-id id]]
//   [--push-relay url --push-relay-token-file path]
//   [--command-scopes [--command-slice name.slice]] (each bash command in its own systemd scope, in tau-cmd.slice or the
//   slice named: src/scopes.ts, docs/command-isolation.md; off by default)
//   [--web dir | --no-web] (the built web app it serves on its port: by default web/ beside a release's bundle, or
//   web/dist in a checkout, when built; docs/web.md)
//   [--check-data] (prints the database's path, then makes the check every start makes, the data on a local
//   filesystem (src/localfs.ts), and exits: 2 with the reason when it fails; `tau setup` asks it before it starts)
// Clients must give the server's token (`Authorization: Bearer <token>`) when it has one: TAU_TOKEN, or else the
// --token-file's (by convention ~/.config/tau/token), which must be readable by its owner only. Without one the server
// listens on loopback only, unless --no-auth: anyone who reaches it can run commands as this user.
// With the account's APNs key (a .p8, owner-only; the key ID from its name AuthKey_<id>.p8), it sends Apple's pushes:
// notifications, and Live Activity updates (docs/notifications.md). Or, with --push-relay, it sends them through a
// relay that holds the key (../relay), with the relay's token from --push-relay-token-file (owner-only).
// Its data (the database, the search index beside it) is in --data, by default $XDG_DATA_HOME/tau or
// ~/.local/share/tau, which only its owner may enter; --db names a database file instead, as the tests do.
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { FileCredentialStore } from "./credentials.ts";
import { DEV_MODEL } from "./dev-model.ts";
import { directory } from "./fs.ts";
import { openHost } from "./host.ts";
import { storageRefusal } from "./localfs.ts";
import { Apns } from "./apns.ts";
import { WebApp } from "./http-web.ts";
import { PushRelay } from "./relay.ts";
import { serve } from "./server.ts";

const { values } = parseArgs({
	options: {
		data: { type: "string" },
		db: { type: "string" },
		memory: { type: "boolean", default: false },
		port: { type: "string", default: "7878" },
		host: { type: "string", default: "127.0.0.1" },
		model: { type: "string" },
		cwd: { type: "string" },
		"dev-tps": { type: "string" },
		"dev-cache-ttl": { type: "string" },
		"token-file": { type: "string" },
		"no-auth": { type: "boolean", default: false },
		"apns-key": { type: "string" },
		"apns-key-id": { type: "string" },
		"apns-team": { type: "string" },
		"push-relay": { type: "string" },
		"push-relay-token-file": { type: "string" },
		"command-scopes": { type: "boolean", default: false },
		"command-slice": { type: "string" },
		"check-data": { type: "boolean", default: false },
		web: { type: "string" },
		"no-web": { type: "boolean", default: false },
		version: { type: "boolean", default: false },
	},
});
if (values.version) {
	// A release's version (scripts/build-release.sh); from the source, "dev".
	console.log(typeof TAU_VERSION === "string" ? TAU_VERSION : "dev");
	process.exit(0);
}

if (values["command-slice"] !== undefined && !values["command-scopes"]) {
	console.error("--command-slice names the slice of --command-scopes, which is off.");
	process.exit(1);
}

if (values["check-data"]) {
	// Before anything is made: the database's path, and then why it cannot be there, if so (exit 2).
	if (values.memory) {
		console.log("memory");
		process.exit(0);
	}
	const path = databasePath({ make: false, refuse: false });
	console.log(path);
	const refusal = storageRefusal(dirname(path), values.db === undefined ? "--data" : "--db");
	if (refusal !== undefined) console.error(refusal);
	process.exit(refusal === undefined ? 0 : 2);
}

const token = readToken();
if (token === undefined && !isLoopback(values.host) && !values["no-auth"]) {
	console.error(`No token, and ${values.host} is not loopback: anyone who reaches it could run commands here.`);
	console.error("Make one:  umask 077 && mkdir -p ~/.config/tau && openssl rand -hex 32 > ~/.config/tau/token");
	console.error("and pass --token-file ~/.config/tau/token; or listen on 127.0.0.1, or pass --no-auth.");
	process.exit(1);
}

const database = values.memory ? undefined : databasePath();
const model = parseModel(values.model ?? `${DEV_MODEL.provider}/${DEV_MODEL.modelId}`);
const credentials = new FileCredentialStore();
const host = await openHost({
	...(database === undefined ? {} : { database }),
	model,
	...(values.cwd === undefined ? {} : { cwd: await directory(values.cwd.startsWith("~") ? values.cwd : resolve(values.cwd)) }),
	...(values["dev-tps"] === undefined ? {} : { devTokensPerSecond: Number(values["dev-tps"]) }),
	...(values["dev-cache-ttl"] === undefined ? {} : { devCacheTtl: Number(values["dev-cache-ttl"]) }),
	credentials,
	...(values["command-scopes"] ? { commandScopes: values["command-slice"] === undefined ? {} : { slice: values["command-slice"] } } : {}),
});
if (host.models.getModel(model.provider, model.modelId) === undefined) {
	console.error(`Unknown model ${model.provider}/${model.modelId}`);
	process.exit(1);
}
const apns = openApns() ?? openRelay();
const web = openWeb();
const server = await serve(host, {
	...(apns === undefined ? {} : { apns }),
	...(web === undefined ? {} : { web }),
	host: values.host,
	port: Number(values.port),
	...(token === undefined ? {} : { token }),
});
console.log(`tau listening on ${server.url}`);
console.log(`  storage  ${database ?? "memory"}`);
console.log(`  model    ${model.provider}/${model.modelId}`);
console.log(`  cwd      ${host.cwd}`);
console.log(`  server   ${host.serverId}`);
console.log(`  apns     ${apns === undefined ? "none" : apns instanceof PushRelay ? `relay ${apns.url}` : `key ${apns.keyId}, team ${apns.teamId}`}`);
console.log(`  web      ${web === undefined ? "none" : web.dir}`);
console.log(`  auth     ${token === undefined ? "none" : process.env.TAU_TOKEN ? "token (TAU_TOKEN)" : `token (${values["token-file"]})`} (credentials: ${credentials.path})`);

let stopping = false;
const stop = async (): Promise<void> => {
	if (stopping) process.exit(1);
	stopping = true;
	console.log("\nstopping...");
	await server.close();
	apns?.close();
	await host.close();
	process.exit(0);
};
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());

/**
 * --db's file, or tau.db in the data directory, made (only its owner may enter it, whatever the umask) if need be and
 * `make`. Refuses, and exits, when it is on a network filesystem.
 */
function databasePath({ make = true, refuse: check = true }: { make?: boolean; refuse?: boolean } = {}): string {
	if (values.db !== undefined && values.data !== undefined) {
		console.error("--db and --data both name the database: give one");
		process.exit(1);
	}
	const refuse = (dir: string, option: "--data" | "--db") => {
		const refusal = check ? storageRefusal(dir, option) : undefined;
		if (refusal === undefined) return;
		console.error(refusal);
		process.exit(2);
	};
	if (values.db !== undefined) {
		const file = resolve(expandHome(values.db));
		refuse(dirname(file), "--db");
		return file;
	}
	const given = values.data ?? join(process.env.XDG_DATA_HOME || join(homedir(), ".local", "share"), "tau");
	const dir = resolve(expandHome(given));
	refuse(dir, "--data");
	if (!make) return join(dir, "tau.db");
	mkdirSync(dir, { recursive: true, mode: 0o700 });
	// Not the umask: the agents' commands inherit it, and the files they make in the user's projects must not change.
	if ((statSync(dir).mode & 0o077) !== 0) chmodSync(dir, 0o700);
	return join(dir, "tau.db");
}

function expandHome(path: string): string {
	return path === "~" ? homedir() : path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

function parseModel(value: string): { provider: string; modelId: string } {
	const slash = value.indexOf("/");
	if (slash <= 0) throw new Error(`--model must be provider/id, got ${value}`);
	return { provider: value.slice(0, slash), modelId: value.slice(slash + 1) };
}

/** TAU_TOKEN, or the token file's, which only its owner may read; undefined when there is neither. */
function readToken(): string | undefined {
	const fromEnvironment = process.env.TAU_TOKEN?.trim();
	if (fromEnvironment) return fromEnvironment;
	const given = values["token-file"];
	if (given === undefined) return undefined;
	const path = given.startsWith("~/") ? join(homedir(), given.slice(2)) : resolve(given);
	if (!existsSync(path)) {
		console.error(`No token file at ${path}`);
		process.exit(1);
	}
	if ((statSync(path).mode & 0o077) !== 0) {
		console.error(`${path} is readable by others: chmod 600 ${path}`);
		process.exit(1);
	}
	const value = readFileSync(path, "utf8").trim();
	if (value.length < 16) {
		console.error(`${path} holds no token of at least 16 characters`);
		process.exit(1);
	}
	return value;
}

function isLoopback(host: string): boolean {
	return host === "localhost" || host === "::1" || /^127\./.test(host);
}

/** Apple's push service with the account's key, when --apns-key gives it. */
function openApns(): Apns | undefined {
	const given = values["apns-key"];
	if (given === undefined) return undefined;
	const team = values["apns-team"];
	if (team === undefined) {
		console.error("--apns-key needs --apns-team, the developer account's team ID");
		process.exit(1);
	}
	try {
		return new Apns({
			keyPath: given.startsWith("~/") ? join(homedir(), given.slice(2)) : resolve(given),
			teamId: team,
			...(values["apns-key-id"] === undefined ? {} : { keyId: values["apns-key-id"] }),
		});
	} catch (error) {
		console.error(`APNs key: ${(error as Error).message}`);
		process.exit(1);
	}
}

/** A push relay that holds the APNs key, when --push-relay gives it (and no --apns-key). */
function openRelay(): PushRelay | undefined {
	const url = values["push-relay"];
	if (url === undefined) return undefined;
	const given = values["push-relay-token-file"];
	if (given === undefined) {
		console.error("--push-relay needs --push-relay-token-file, the relay's token for this server");
		process.exit(1);
	}
	const path = given.startsWith("~/") ? join(homedir(), given.slice(2)) : resolve(given);
	try {
		if ((statSync(path).mode & 0o077) !== 0) throw new Error(`${path} is readable by others: chmod 600 ${path}`);
		return new PushRelay(url, readFileSync(path, "utf8").trim());
	} catch (error) {
		console.error(`Push relay token: ${(error as Error).message}`);
		process.exit(1);
	}
}

/** The web app to serve: --web's, else the release's or the checkout's build, when there is one. */
function openWeb(): WebApp | undefined {
	if (values["no-web"]) return undefined;
	if (values.web !== undefined) {
		const app = WebApp.at(resolve(expandHome(values.web)));
		if (app === undefined) {
			console.error(`No web app at ${values.web} (no index.html): build it with scripts/web/build.sh`);
			process.exit(1);
		}
		return app;
	}
	const beside = typeof TAU_VERSION === "string" ? join(import.meta.dirname, "web") : join(import.meta.dirname, "..", "..", "web", "dist");
	return WebApp.at(beside);
}
