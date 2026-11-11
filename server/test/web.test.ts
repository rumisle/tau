// The web app on the server's port (src/http-web.ts) and a browser's token, in the WebSocket's subprotocol.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { get } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { WebSocket } from "ws";
import { TauClient } from "tau-client/connection";
import { type Host, openHost } from "../src/host.ts";
import { WebApp } from "../src/http-web.ts";
import { type Server, serve } from "../src/server.ts";

const TOKEN = "a-token-long-enough-to-pass";

describe("web app", () => {
	let host: Host;
	let server: Server;
	let base: string;
	let dir: string;
	before(async () => {
		dir = mkdtempSync(join(tmpdir(), "tau-web-"));
		mkdirSync(join(dir, "assets"));
		writeFileSync(join(dir, "index.html"), "<!doctype html><title>tau</title>");
		writeFileSync(join(dir, "assets", "index-B4x9Qf2a.js"), "console.log(1)");
		host = await openHost({ cwd: tmpdir() });
		server = await serve(host, { token: TOKEN, web: WebApp.at(dir)! });
		base = server.url.replace("ws://", "http://");
	});
	after(async () => {
		await server.close();
		await host.close();
		rmSync(dir, { recursive: true, force: true });
	});

	test("serves the app without a token: index.html for the app's routes, hashed assets for good", async () => {
		for (const path of ["/", "/index.html", "/#1234", "/some/route"]) {
			const response = await fetch(base + path);
			assert.equal(response.status, 200, path);
			assert.equal(response.headers.get("content-type"), "text/html; charset=utf-8");
			assert.equal(response.headers.get("cache-control"), "no-cache");
			assert.match(await response.text(), /<title>tau/);
		}
		const asset = await fetch(`${base}/assets/index-B4x9Qf2a.js`);
		assert.equal(asset.headers.get("cache-control"), "public, max-age=31536000, immutable");
		assert.equal(asset.headers.get("content-type"), "text/javascript; charset=utf-8");
		assert.equal((await fetch(`${base}/assets/missing-AAAAAAAA.js`)).status, 404);
		// A path out of the app's directory, escaped so the client sends it as it is, gets the app, not the file
		const escaped = await new Promise<string>((resolve) => {
			get(`${base}/%2e%2e/%2e%2e/%2e%2e/etc/hostname`, (response) => {
				let body = "";
				response.on("data", (chunk) => (body += chunk));
				response.on("end", () => resolve(body));
			});
		});
		assert.match(escaped, /<title>tau/);
	});

	test("keeps files and /auth behind the token: /auth answers whether a token is taken", async () => {
		assert.equal((await fetch(`${base}/auth`)).status, 401);
		assert.equal((await fetch(`${base}/auth`, { headers: { authorization: "Bearer another-token-of-the-length" } })).status, 401);
		assert.equal((await fetch(`${base}/auth`, { headers: { authorization: `Bearer ${TOKEN}` } })).status, 204);
		assert.equal((await fetch(`${base}/files/${"0".repeat(32)}`)).status, 401);
	});

	test("takes a browser's token in the subprotocol, answering with tau.v1", async () => {
		const protocols = ["tau.v1", `tau.token.${Buffer.from(TOKEN).toString("base64url")}`];
		const socket = new WebSocket(`${server.url}/socket`, protocols);
		const client = await TauClient.open(socket);
		assert.equal(socket.protocol, "tau.v1");
		assert.equal(client.hello?.protocol, 1);
		await client.close();
		const wrong = new WebSocket(`${server.url}/socket`, ["tau.v1", `tau.token.${Buffer.from("not-the-token").toString("base64url")}`]);
		await assert.rejects(TauClient.open(wrong), /401/);
	});
});
