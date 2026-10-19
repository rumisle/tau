// tau server: `node src/main.ts [--db path] [--port n] [--host addr] [--model provider/id] [--cwd dir] [--memory]
//   [--dev-tps n]` (speed of the dev/echo model, tokens per second)
// TAU_TOKEN, when set, is required from clients.
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
	},
});

const model = parseModel(values.model ?? `${DEV_MODEL.provider}/${DEV_MODEL.modelId}`);
const credentials = new FileCredentialStore();
const host = await openHost({
	...(values.memory ? {} : { database: values.db }),
	model,
	...(values.cwd === undefined ? {} : { cwd: await directory(values.cwd.startsWith("~") ? values.cwd : resolve(values.cwd)) }),
	...(values["dev-tps"] === undefined ? {} : { devTokensPerSecond: Number(values["dev-tps"]) }),
	credentials,
});
if (host.models.getModel(model.provider, model.modelId) === undefined) {
	console.error(`Unknown model ${model.provider}/${model.modelId}`);
	process.exit(1);
}
const server = await serve(host, {
	host: values.host,
	port: Number(values.port),
	...(process.env.TAU_TOKEN ? { token: process.env.TAU_TOKEN } : {}),
});
console.log(`tau listening on ${server.url}`);
console.log(`  storage  ${values.memory ? "memory" : values.db}`);
console.log(`  model    ${model.provider}/${model.modelId}`);
console.log(`  cwd      ${host.cwd}`);
console.log(`  server   ${host.serverId}`);
console.log(`  auth     ${process.env.TAU_TOKEN ? "token" : "none"} (credentials: ${credentials.path})`);

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
