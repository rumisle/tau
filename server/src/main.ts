// tau server: `node src/main.ts [--db path] [--port n] [--host addr] [--model provider/id] [--cwd dir] [--memory]
//   [--dev-tps n] [--dev-cache-ttl s]` (speed of the dev/echo model, tokens per second; a prompt cache lifetime that makes it
//   charge as a costly model, to try cache warming)
//   [--token-file path] [--no-auth]
// Clients must give the server's token (`Authorization: Bearer <token>`) when it has one: TAU_TOKEN, or else the
// --token-file's (by convention ~/.config/tau/token), which must be readable by its owner only. Without one the server
// listens on loopback only, unless --no-auth: anyone who reaches it can run commands as this user.
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { FileCredentialStore } from "./credentials.ts";
import { DEV_MODEL } from "./dev-model.ts";
import { directory } from "./fs.ts";
import { openHost } from "./host.ts";
import { serve } from "./server.ts";

const { values } = parseArgs({
	options: {
		db: { type: "string", default: join(import.meta.dirname, "..", "..", "data", "tau.sqlite") },
		memory: { type: "boolean", default: false },
		port: { type: "string", default: "7878" },
		host: { type: "string", default: "127.0.0.1" },
		model: { type: "string" },
		cwd: { type: "string" },
		"dev-tps": { type: "string" },
		"dev-cache-ttl": { type: "string" },
		"token-file": { type: "string" },
		"no-auth": { type: "boolean", default: false },
	},
});

const token = readToken();
if (token === undefined && !isLoopback(values.host) && !values["no-auth"]) {
	console.error(`No token, and ${values.host} is not loopback: anyone who reaches it could run commands here.`);
	console.error("Make one:  umask 077 && mkdir -p ~/.config/tau && openssl rand -base64 32 | tr -d '\\n=' | tr '+/' '-_' > ~/.config/tau/token");
	console.error("and pass --token-file ~/.config/tau/token; or listen on 127.0.0.1, or pass --no-auth.");
	process.exit(1);
}

const model = parseModel(values.model ?? `${DEV_MODEL.provider}/${DEV_MODEL.modelId}`);
const credentials = new FileCredentialStore();
const host = await openHost({
	...(values.memory ? {} : { database: values.db }),
	model,
	...(values.cwd === undefined ? {} : { cwd: await directory(values.cwd.startsWith("~") ? values.cwd : resolve(values.cwd)) }),
	...(values["dev-tps"] === undefined ? {} : { devTokensPerSecond: Number(values["dev-tps"]) }),
	...(values["dev-cache-ttl"] === undefined ? {} : { devCacheTtl: Number(values["dev-cache-ttl"]) }),
	credentials,
});
if (host.models.getModel(model.provider, model.modelId) === undefined) {
	console.error(`Unknown model ${model.provider}/${model.modelId}`);
	process.exit(1);
}
const server = await serve(host, {
	host: values.host,
	port: Number(values.port),
	...(token === undefined ? {} : { token }),
});
console.log(`tau listening on ${server.url}`);
console.log(`  storage  ${values.memory ? "memory" : values.db}`);
console.log(`  model    ${model.provider}/${model.modelId}`);
console.log(`  cwd      ${host.cwd}`);
console.log(`  server   ${host.serverId}`);
console.log(`  auth     ${token === undefined ? "none" : process.env.TAU_TOKEN ? "token (TAU_TOKEN)" : `token (${values["token-file"]})`} (credentials: ${credentials.path})`);

let stopping = false;
const stop = async (): Promise<void> => {
	if (stopping) process.exit(1);
	stopping = true;
	console.log("\nstopping...");
	await server.close();
	await host.close();
	process.exit(0);
};
process.on("SIGINT", () => void stop());
process.on("SIGTERM", () => void stop());

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
