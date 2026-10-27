import assert from "node:assert/strict";
import { createDecipheriv, createPublicKey, generateKeyPairSync, randomBytes, verify } from "node:crypto";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer } from "node:http2";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { Apns, type ApnsPush, type ApnsResult, activityDate } from "../src/apns.ts";
import { ConversationReplica, TauClient } from "../src/client.ts";
import { DevicesDoc } from "../src/devices.ts";
import { type Host, openHost } from "../src/host.ts";
import { PushRelay } from "../src/relay.ts";
import { type Server, serve } from "../src/server.ts";

function until(predicate: () => boolean, timeoutMs = 10_000): Promise<void> {
	return new Promise((resolve, reject) => {
		const started = Date.now();
		const check = () => {
			if (predicate()) resolve();
			else if (Date.now() - started > timeoutMs) reject(new Error("timed out"));
			else setTimeout(check, 20);
		};
		check();
	});
}

const idle = (replica: ConversationReplica) => (replica.docs["pi.live"] as { run?: unknown } | undefined)?.run === undefined;

async function chat(client: TauClient, replica: ConversationReplica, content: string, requestId: string): Promise<void> {
	const { submission } = await client.request("conversation.submit", { conversationId: replica.id, requestId, content });
	await until(() => replica.submissions.get(submission.id)?.status === "done" && idle(replica));
}

function keyFile(directory: string): string {
	const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
	const path = join(directory, "AuthKey_ABCDE12345.p8");
	writeFileSync(path, privateKey.export({ type: "pkcs8", format: "pem" }));
	chmodSync(path, 0o600);
	return path;
}

describe("APNs", () => {
	let directory: string;
	before(() => {
		directory = mkdtempSync(join(tmpdir(), "tau-apns-"));
	});
	after(() => rmSync(directory, { recursive: true, force: true }));

	test("signs its provider token with the key, and keeps it for a while", () => {
		const path = keyFile(directory);
		let now = 1_000_000_000_000;
		const apns = new Apns({ keyPath: path, teamId: "TEAM123456", now: () => now });
		assert.equal(apns.keyId, "ABCDE12345", "the key ID from the file name");
		const token = apns.token();
		const [header, claims, signature] = token.split(".");
		assert.deepEqual(JSON.parse(Buffer.from(header!, "base64url").toString()), { alg: "ES256", kid: "ABCDE12345" });
		assert.deepEqual(JSON.parse(Buffer.from(claims!, "base64url").toString()), { iss: "TEAM123456", iat: 1_000_000_000 });
		const publicKey = createPublicKey(readFileSync(path, "utf8"));
		assert.ok(verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature!, "base64url")));
		now += 49 * 60_000;
		assert.equal(apns.token(), token, "the same within the hour");
		now += 2 * 60_000;
		assert.notEqual(apns.token(), token, "a new one before Apple's hour is up");
		apns.close();
	});

	test("refuses a key others can read", () => {
		const path = keyFile(directory);
		chmodSync(path, 0o644);
		assert.throws(() => new Apns({ keyPath: path, teamId: "TEAM123456" }), /readable by others/);
	});

	test("sends over HTTP/2 with Apple's headers, and reads a refusal", async () => {
		const requests: { headers: Record<string, unknown>; body: string }[] = [];
		const server = createServer((request, response) => {
			let body = "";
			request.setEncoding("utf8");
			request.on("data", (chunk) => (body += chunk));
			request.on("end", () => {
				requests.push({ headers: request.headers, body });
				if (request.headers[":path"] === "/3/device/gone") {
					response.writeHead(410, { "apns-id": "x" });
					response.end(JSON.stringify({ reason: "Unregistered" }));
				} else {
					response.writeHead(200, { "apns-id": String(request.headers["apns-id"]) });
					response.end();
				}
			});
		});
		await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
		const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
		const apns = new Apns({ keyPath: keyFile(directory), teamId: "TEAM123456", origins: { development: origin } });
		try {
			const push: ApnsPush = { type: "alert", topic: "com.example.tau", priority: 10, payload: { aps: { alert: { title: "t", body: "b" } } } };
			const ok = await apns.send({ token: "abc", environment: "development" }, push);
			assert.equal(ok.status, 200);
			const gone = await apns.send({ token: "gone", environment: "development" }, push);
			assert.deepEqual({ status: gone.status, reason: gone.reason }, { status: 410, reason: "Unregistered" });
			const first = requests[0]!;
			assert.equal(first.headers[":path"], "/3/device/abc");
			assert.equal(first.headers["apns-push-type"], "alert");
			assert.equal(first.headers["apns-topic"], "com.example.tau");
			assert.equal(first.headers["apns-priority"], "10");
			assert.match(String(first.headers.authorization), /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
			assert.deepEqual(JSON.parse(first.body), push.payload);
		} finally {
			apns.close();
			await new Promise<void>((resolve) => server.close(() => resolve()));
		}
	});
});

describe("pushes", () => {
	let host: Host;
	let server: Server;
	const pushes: { device: { token: string }; push: ApnsPush }[] = [];
	let refuse: ((token: string) => ApnsResult | undefined) | undefined;
	before(async () => {
		host = await openHost({ devTokensPerSecond: 2_000, cwd: tmpdir() });
		server = await serve(host, {
			activityDoneLifetimeMs: 500,
			apns: {
				send: async (device, push) => {
					pushes.push({ device, push });
					return refuse?.(device.token) ?? { status: 200 };
				},
			},
		});
	});
	after(async () => {
		await server.close();
		await host.close();
	});

	const aps = (push: ApnsPush) => (push.payload as { aps: Record<string, unknown> }).aps;

	test("an answer goes to each device that wants answers, with the chat to open", async () => {
		const client = await TauClient.connect(server.url);
		assert.equal(((await client.request("hello", { protocol: 1 })) as { apns: boolean }).apns, true);
		await client.request("devices.register", { deviceId: "phone", environment: "development", topic: "com.example.tau", token: "t-phone" });
		await client.request("devices.register", { deviceId: "quiet", environment: "production", topic: "com.example.tau", token: "t-quiet", alerts: false });
		const { dialog } = await client.request("conversation.create", { title: "Push me" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const before = pushes.length;
		await chat(client, replica, "hello", "p1");
		await until(() => pushes.length > before);
		const sent = pushes.slice(before);
		assert.deepEqual(sent.map((each) => each.device.token), ["t-phone"], "not to the one that turned answers off");
		const push = sent[0]!.push;
		assert.equal(push.type, "alert");
		assert.equal(push.topic, "com.example.tau");
		assert.deepEqual(aps(push).alert, { title: "Push me", body: (aps(push).alert as { body: string }).body });
		assert.match((aps(push).alert as { body: string }).body, /You said: hello/);
		assert.equal(aps(push)["thread-id"], `${host.serverId}:${replica.id}`);
		assert.equal(aps(push)["mutable-content"], 1);
		assert.equal(aps(push).category, "chat");
		assert.deepEqual((push.payload as { tau: { server: string; id: number } }).tau.id, replica.id);
		// In the foreground the app shows its own banner: nothing is pushed.
		await client.request("client.presence", { active: true });
		const quiet = pushes.length;
		await chat(client, replica, "again", "p2");
		await new Promise((resolve) => setTimeout(resolve, 100));
		assert.equal(pushes.length, quiet);
		await client.close();
	});

	test("an answer to a device with a push key is sealed: only the app can read it", async () => {
		const client = await TauClient.connect(server.url);
		const key = randomBytes(32).toString("base64");
		await assert.rejects(client.request("devices.register", { deviceId: "sealed", environment: "production", topic: "com.example.tau", token: "t-sealed", pushKey: "short" }));
		await client.request("devices.register", { deviceId: "sealed", environment: "production", topic: "com.example.tau", token: "t-sealed", pushKey: key });
		const { dialog } = await client.request("conversation.create", { title: "Secret chat" });
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		const before = pushes.length;
		await chat(client, replica, "the password is swordfish", "s1");
		await until(() => pushes.some((each, i) => i >= before && each.device.token === "t-sealed"));
		const push = pushes.slice(before).find((each) => each.device.token === "t-sealed")!.push;
		const raw = JSON.stringify(push.payload);
		assert.ok(!raw.includes("swordfish") && !raw.includes("Secret chat"), "neither the answer nor the title in the clear");
		assert.deepEqual(aps(push).alert, { title: "tau", body: "New message" });
		const tau = (push.payload as { tau: { server: string; id: number; sealed: string } }).tau;
		assert.equal(tau.id, replica.id);
		const bytes = Buffer.from(tau.sealed, "base64");
		const decipher = createDecipheriv("aes-256-gcm", Buffer.from(key, "base64"), bytes.subarray(0, 12));
		decipher.setAuthTag(bytes.subarray(bytes.length - 16));
		const opened = JSON.parse(Buffer.concat([decipher.update(bytes.subarray(12, bytes.length - 16)), decipher.final()]).toString("utf8"));
		assert.equal(opened.title, "Secret chat");
		assert.match(opened.body, /swordfish/);
		assert.match(opened.url, /^tau:\/\//);
		await client.request("devices.unregister", { deviceId: "sealed" });
		await client.close();
	});

	test("forgets a device token Apple says is gone", async () => {
		const client = await TauClient.connect(server.url);
		await client.request("devices.register", { deviceId: "old", environment: "development", topic: "com.example.tau", token: "t-old" });
		refuse = (token) => (token === "t-old" ? { status: 410, reason: "Unregistered" } : undefined);
		const { dialog } = await client.request("conversation.create", {});
		const replica = new ConversationReplica(dialog.conversation.id);
		await replica.sync(client);
		await chat(client, replica, "hello", "g1");
		await until(() => pushes.some((each) => each.device.token === "t-old"));
		await new Promise((resolve) => setTimeout(resolve, 50));
		const devices = (await host.harness.snapshot(DevicesDoc, BACKGROUND_CONTEXT))!.devices;
		assert.equal(devices.old?.token, undefined);
		refuse = undefined;
		await client.request("devices.unregister", { deviceId: "old" });
		await client.close();
	});

	test("a chat in a Live Activity: its finish updates the activity, with the alert, instead of a notification, and it ends later", async () => {
		const client = await TauClient.connect(server.url);
		await client.request("devices.register", { deviceId: "la", environment: "development", topic: "com.example.tau", token: "t-la" });
		const { dialog } = await client.request("conversation.create", { title: "Waiting" });
		const id = dialog.conversation.id;
		const replica = new ConversationReplica(id);
		await replica.sync(client);
		const since = Date.now();
		await client.request("liveActivity.update", {
			deviceId: "la",
			activity: { id: "activity-1", token: "t-activity", accent: 0xeb6ca4, rows: [{ appId: id, conversationId: id, title: "Waiting", state: "working", since, detail: "Working", watchedAt: since }] },
		});
		const before = pushes.length;
		await chat(client, replica, "hello", "l1");
		await until(() => pushes.slice(before).filter((each) => each.push.type === "liveactivity").length >= 1);
		await new Promise((resolve) => setTimeout(resolve, 100));
		assert.equal(pushes.slice(before).filter((each) => each.push.type === "liveactivity").length, 1, "the done row stays a while");
		await until(() => pushes.slice(before).filter((each) => each.push.type === "liveactivity").length >= 2);
		const sent = pushes.slice(before).filter((each) => each.device.token !== "t-phone");
		assert.deepEqual(
			sent.map((each) => [each.device.token, each.push.type, aps(each.push).event ?? null]),
			[
				["t-activity", "liveactivity", "update"],
				["t-activity", "liveactivity", "end"],
			],
			"no notification to the device whose activity says it",
		);
		const update = sent[0]!.push;
		assert.equal(update.topic, "com.example.tau.push-type.liveactivity");
		assert.equal(update.priority, 10);
		const state = aps(update)["content-state"] as { chats: Record<string, unknown>[]; more: number; accent: number };
		assert.equal(state.more, 0);
		assert.equal(state.accent, 0xeb6ca4);
		const chat0 = state.chats[0]!;
		assert.equal(chat0.state, "done");
		assert.equal(chat0.serverId, host.serverId);
		assert.equal(chat0.localId, id);
		assert.equal(chat0.since, activityDate(since));
		assert.ok(typeof chat0.finishedAt === "number");
		assert.match(String(chat0.detail), /You said: hello/);
		assert.match((aps(update).alert as { body: string }).body, /^Done · worked under a minute · You said: hello/);
		const end = sent[1]!.push;
		assert.ok((end.payload as { aps: { timestamp: number } }).aps.timestamp - (aps(update).timestamp as number) >= 0, "after the update");
		assert.ok((aps(end).timestamp as number) > (aps(update).timestamp as number), "each push later than the last");
		const devices = (await host.harness.snapshot(DevicesDoc, BACKGROUND_CONTEXT))!.devices;
		assert.equal(devices.la?.activity, undefined, "ended");
		await client.request("devices.unregister", { deviceId: "la" });
		await client.close();
	});

	test("starts an activity with the push-to-start token when the app cannot", async () => {
		const client = await TauClient.connect(server.url);
		await client.request("devices.register", { deviceId: "start", environment: "development", topic: "com.example.tau", pushToStart: "t-start" });
		const now = Date.now();
		const { result } = (await client.request("liveActivity.start", { deviceId: "start", rows: [{ appId: 5, conversationId: 5, title: "Replied", state: "working", since: now, watchedAt: now }] })) as { result: string };
		assert.equal(result, "started");
		const push = pushes.at(-1)!;
		assert.equal(push.device.token, "t-start");
		assert.equal(aps(push.push).event, "start");
		assert.equal(aps(push.push)["attributes-type"], "TauActivityAttributes");
		assert.deepEqual(aps(push.push).attributes, { serverId: host.serverId });
		assert.deepEqual(aps(push.push).alert, { title: "Replied", body: "Working" });
		await client.request("devices.unregister", { deviceId: "start" });
		await client.close();
	});
});

describe("push relay", () => {
	test("sends the push with its token and reads Apple's answer; a refusal of its own rejects", async () => {
		const requests: { authorization?: string; body: Record<string, unknown> }[] = [];
		const relay = createHttpServer((request, response) => {
			let text = "";
			request.on("data", (chunk) => (text += chunk));
			request.on("end", () => {
				requests.push({ authorization: request.headers.authorization, body: JSON.parse(text) });
				if (request.headers.authorization !== "Bearer secret") {
					response.writeHead(401).end(JSON.stringify({ error: "unauthorized" }));
					return;
				}
				response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ status: 410, reason: "Unregistered", id: "x" }));
			});
		});
		await new Promise<void>((resolve) => relay.listen(0, "127.0.0.1", resolve));
		const url = `http://127.0.0.1:${(relay.address() as AddressInfo).port}/`;
		try {
			const push: ApnsPush = { type: "alert", topic: "com.example.tau", priority: 10, payload: { aps: { alert: "hi" } } };
			const result = await new PushRelay(url, "secret").send({ token: "abc", environment: "production" }, push);
			assert.deepEqual(result, { status: 410, reason: "Unregistered", id: "x" });
			assert.deepEqual(requests[0]!.body, { token: "abc", environment: "production", ...push });
			await assert.rejects(new PushRelay(url, "wrong").send({ token: "abc", environment: "production" }, push), /relay 401/);
		} finally {
			await new Promise<void>((resolve) => relay.close(() => resolve()));
		}
	});
});
