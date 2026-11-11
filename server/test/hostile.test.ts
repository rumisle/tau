// Whatever reaches the port, the server answers or refuses, and goes on: hostile request targets, headers and
// handshakes, with and without a token and the web app. Requests are written raw, as no well-behaved client sends them.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { type Host, openHost } from "../src/host.ts";
import { WebApp } from "../src/http-web.ts";
import { type Server, serve } from "../src/server.ts";

const TOKEN = "a-token-long-enough-to-pass";

/** Sends `request` as written and returns the status line's code, as soon as it comes (0 when the server closed first). */
function raw(port: number, request: string): Promise<number> {
	return new Promise((resolve, reject) => {
		// Its side stays open: a server that sees the end of a request may close before it answers
		const socket = connect(port, "127.0.0.1", () => socket.write(request));
		let reply = "";
		socket.on("data", (chunk) => {
			reply += chunk;
			const status = /^HTTP\/1\.1 (\d{3})/.exec(reply)?.[1];
			if (status === undefined) return;
			socket.destroy();
			resolve(Number(status));
		});
		socket.on("error", () => resolve(0));
		socket.on("close", () => resolve(0));
		socket.setTimeout(5_000, () => reject(new Error(`no answer to ${JSON.stringify(request.split("\r\n")[0])}`)));
	});
}

const get = (target: string, headers: Record<string, string> = {}) =>
	`GET ${target} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n${Object.entries(headers).map(([key, value]) => `${key}: ${value}\r\n`).join("")}\r\n`;

const upgrade = (target: string, protocol?: string) =>
	get(target, {
		Upgrade: "websocket",
		Connection: "Upgrade",
		"Sec-WebSocket-Version": "13",
		"Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
		...(protocol === undefined ? {} : { "Sec-WebSocket-Protocol": protocol }),
	}).replace("Connection: close\r\n", "");

const TARGETS = [
	"/%E0%A4%A", "/%", "/%ZZ", "/assets/%E0%A4%A.js", "/%00", "/a%00.js", "//", "///", "//x/y", "http://[", "http://[::1/",
	"http://example.com/../../etc/passwd", "/files/%E0%A4%A", "/files/%", "/files//", "/auth?token=%E0%A4%A",
	"/?token=%", "/x?%=%", `/${"a".repeat(8_000)}.js`, `/${"%2e%2e/".repeat(20)}etc/hostname`, "*",
];

describe("hostile requests", () => {
	let host: Host;
	let dir: string;
	const servers: { name: string; server: Server; port: number }[] = [];
	before(async () => {
		dir = mkdtempSync(join(tmpdir(), "tau-web-"));
		writeFileSync(join(dir, "index.html"), "<!doctype html><title>tau</title>");
		host = await openHost({ cwd: tmpdir() });
		for (const [name, options] of [
			["token and web", { token: TOKEN, web: WebApp.at(dir)! }],
			["web without a token", { web: WebApp.at(dir)! }],
			["token without web", { token: TOKEN }],
		] as const) {
			const server = await serve(host, options);
			servers.push({ name, server, port: Number(new URL(server.url).port) });
		}
	});
	after(async () => {
		for (const { server } of servers) await server.close();
		await host.close();
		rmSync(dir, { recursive: true, force: true });
	});

	test("request targets that do not decode or parse are answered, never with a 5xx, and the server goes on", async () => {
		for (const { name, port } of servers) {
			for (const target of TARGETS) {
				// The app, a refusal or not found; never a failure, never silence
				const status = await raw(port, get(target));
				assert.ok(status >= 200 && status < 500, `${name}: ${target} -> ${status}`);
			}
			assert.equal(await raw(port, get("/auth", { Authorization: `Bearer ${TOKEN}` })), 204, `${name} still answers`);
		}
	});

	test("a malformed path is a 400 from the web app, before anything else", async () => {
		const { port } = servers[0]!;
		assert.equal(await raw(port, get("/%E0%A4%A")), 400);
		assert.equal(await raw(port, get("/%00")), 400);
		assert.equal(await raw(port, get("//")), 400);
	});

	test("hostile authorization headers are refused, not thrown on", async () => {
		const { port } = servers[0]!;
		for (const value of ["Bearer", "Bearer ", "Bearer \u00ff\u00fe", `Bearer ${TOKEN}x`, `Bearer ${"x".repeat(10_000)}`, "Basic Zm9vOmJhcg==", "Bearer %E0%A4%A"]) {
			assert.equal(await raw(port, get("/auth", { Authorization: value })), 401, value.slice(0, 40));
		}
		assert.equal(await raw(port, get("/files/0", { Range: "bytes=-0, 99999999999999999999-" })), 401);
		// With the token, a hostile range on a file that does not exist
		assert.equal(await raw(port, get(`/files/${"0".repeat(32)}`, { Authorization: `Bearer ${TOKEN}`, Range: "bytes=99999999999999999999-1" })), 404);
	});

	test("hostile WebSocket handshakes are refused, and the server still upgrades a good one", async () => {
		for (const { name, port } of servers) {
			for (const [target, protocol] of [
				["//", undefined], ["/%E0%A4%A", undefined], ["http://[", undefined], ["/socket?token=%", undefined],
				["/socket", "tau.token.!!!***"], ["/socket", "tau.token."], ["/socket", ",,,"], ["/socket", "tau.v1, tau.v1"],
				["/socket", "tau.v1,\u00e9"], ["/socket", `tau.v1, tau.token.${"A".repeat(20_000)}`], ["/socket", " "],
			] as const) {
				const status = await raw(port, upgrade(target, protocol));
				// Refused (400, 401) or, without a token, upgraded: never a failure
				assert.ok(status === 0 || (status >= 101 && status < 500), `${name}: ${target} ${protocol} -> ${status}`);
			}
			const good = `tau.v1, tau.token.${Buffer.from(TOKEN).toString("base64url")}`;
			assert.equal(await raw(port, upgrade("/socket", good)), 101, `${name} still upgrades`);
		}
	});

	test("a failure of the server's own is a 500 and a log line, and the server goes on", async () => {
		const broken = { handle: () => { throw new Error("boom"); } } as unknown as WebApp;
		const server = await serve(host, { web: broken });
		const logged: string[] = [];
		const error = console.error;
		console.error = (line: string) => logged.push(line);
		try {
			const port = Number(new URL(server.url).port);
			assert.equal(await raw(port, get("/")), 500);
			assert.match(logged.join("\n"), /GET \/ failed: Error: boom/);
			assert.equal(await raw(port, get("/auth")), 204);
		} finally {
			console.error = error;
			await server.close();
		}
	});
});
