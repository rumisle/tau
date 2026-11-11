// WebSocket transport: one Connection per socket, optional bearer token.
import { timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import { Connection } from "./connection.ts";
import { Dialogs } from "./dialogs.ts";
import { handleFiles } from "./http-files.ts";
import type { WebApp, WebDevProxy } from "./http-web.ts";
import type { Host } from "./host.ts";
import { Notifier, type PushSender } from "./notifier.ts";
import { Search } from "./search/service.ts";
import { Titler } from "./titles.ts";

export type ServerOptions = {
	host?: string;
	port?: number;
	/**
	 * Required when set: as `Authorization: Bearer <token>`, `?token=<token>`, or on a WebSocket from a browser, which
	 * cannot set headers, as the subprotocol `tau.token.<token in base64url>` beside `tau.v1` (docs/web.md).
	 */
	token?: string;
	/** The built web app to serve (src/http-web.ts); none when undefined. */
	web?: WebApp | WebDevProxy;
	/** Apple's push service, with the account's key (src/apns.ts); without it, no pushes. */
	apns?: PushSender;
	/** For tests: how long an activity whose chats are all done stays (half an hour). */
	activityDoneLifetimeMs?: number;
	/** For tests: how long a socket may stay silent (IDLE_TIMEOUT_MS). */
	idleTimeoutMs?: number;
};

/**
 * A socket nothing came in on for this long is gone: a phone that lost its network without a word, or one suspended
 * in the background. It is closed, so its connection stops counting as an app in the foreground (which holds every
 * push back) and stops being sent to. The app pings every 15 seconds; the server pings as often, so a client that only
 * answers pings (ws does by itself) is heard too. Bytes of a frame still arriving count, however long the frame.
 */
const IDLE_TIMEOUT_MS = 45_000;

export type Server = {
	readonly url: string;
	readonly notifier: Notifier;
	close(): Promise<void>;
};

export async function serve(host: Host, options: ServerOptions = {}): Promise<Server> {
	const dialogs = new Dialogs(host);
	const titler = new Titler(host);
	const notifier = new Notifier(host, {
		...(options.apns === undefined ? {} : { apns: options.apns }),
		...(options.activityDoneLifetimeMs === undefined ? {} : { doneLifetimeMs: options.activityDoneLifetimeMs }),
	});
	// Beside the database, or in memory with it.
	const search = new Search(host, host.database === undefined ? ":memory:" : searchIndexPath(host.database));
	host.history.index = search;
	// A pending file an entry names is kept, not swept (src/files.ts).
	host.files.referenced = (id) => search.referencesFile(id);
	void host.files.sweep().catch(() => {});
	const connections = new Set<Connection>();
	// HTTP for files (src/http-files.ts) behind the same token, `/auth` to ask whether a token is taken (204 or 401),
	// and the web app (src/http-web.ts) without one; the WebSocket upgrades on the same port.
	// Anyone who reaches the port may send anything: nothing a request carries may throw out of here, where it would
	// end the process. A request it cannot read is a 400; a failure of the server's own, a 500 and a log line.
	const http = createServer((request, response) => {
		try {
			const url = requestUrl(request);
			if (url === undefined) return fail(request, response, 400, "bad_request", "The request's path cannot be read");
			const path = url.pathname;
			const isApi = path === "/auth" || path === "/files" || path.startsWith("/files/");
			if (!isApi && options.web?.handle(request, response)) return;
			// The web app served by another tau server reaches this one's API too (docs/web.md "Several servers"):
			// any origin may, since the bearer token, not a cookie, is what authorizes.
			if (allowCrossOrigin(request, response)) return;
			if (!authorized(request, options.token)) return fail(request, response, 401, "unauthorized", "A token is needed");
			if (path === "/auth") {
				response.writeHead(204, { "Cache-Control": "no-store" });
				response.end();
				return;
			}
			handleFiles(host.files, request, response).catch((error: unknown) => failed(request, response, error));
		} catch (error) {
			failed(request, response, error);
		}
	});
	// A large upload over a slow link takes as long as it takes; a stalled one is cut after a few minutes.
	http.requestTimeout = 0;
	http.timeout = 5 * 60 * 1000;
	const wss = new WebSocketServer({
		server: http,
		// Streamed chunks are a few hundred bytes, most of it the same path each time, which the context the socket
		// keeps compresses to a few bytes: compress them too (docs/network.md).
		perMessageDeflate: { threshold: 64 },
		// Above the content limits of conversation.submit, so too much content is refused with `too_large` instead
		// of closing the socket, which the client would take for a network failure and retry forever.
		maxPayload: 96 * 1024 * 1024,
		verifyClient: ({ req }: { req: IncomingMessage }) => {
			try {
				return authorized(req, options.token);
			} catch (error) {
				console.error(`refused a WebSocket on a failure: ${error instanceof Error ? error.stack : String(error)}`);
				return false;
			}
		},
		// A browser's socket offers `tau.v1` beside its token, and must be answered with one it offered.
		handleProtocols: (protocols) => (protocols.has(PROTOCOL) ? PROTOCOL : false),
	});
	wss.on("connection", (socket, request) => {
		const connection = new Connection(host, dialogs, socket, notifier, search);
		connections.add(connection);
		const idle = options.idleTimeoutMs ?? IDLE_TIMEOUT_MS;
		let heard = Date.now();
		request.socket.on("data", () => {
			heard = Date.now();
		});
		const watchdog = setInterval(() => {
			if (Date.now() - heard > idle) socket.terminate();
			else socket.ping();
		}, idle / 3);
		watchdog.unref();
		// Frames are handled concurrently; responses carry request IDs.
		socket.on("message", (data, isBinary) => {
			if (isBinary) socket.close(1003, "text frames only");
			else void connection.receive(data.toString());
		});
		socket.on("close", () => {
			clearInterval(watchdog);
			connections.delete(connection);
			void connection.close();
		});
		socket.on("error", () => socket.close());
	});
	await new Promise<void>((resolve, reject) => {
		http.once("error", reject);
		http.listen(options.port ?? 0, options.host ?? "127.0.0.1", () => resolve());
	});
	const address = http.address() as AddressInfo;
	return {
		url: `ws://${address.address.includes(":") ? `[${address.address}]` : address.address}:${address.port}`,
		notifier,
		close: async () => {
			for (const client of wss.clients) client.terminate();
			await Promise.allSettled([...connections].map((connection) => connection.close()));
			dialogs.close();
			titler.close();
			notifier.close();
			host.files.referenced = undefined;
			search.close();
			await new Promise<void>((resolve) => wss.close(() => resolve()));
			http.closeAllConnections();
			await new Promise<void>((resolve) => http.close(() => resolve()));
		},
	};
}

const PROTOCOL = "tau.v1";
const TOKEN_PROTOCOL = "tau.token.";

/** The request's URL, or undefined when its target cannot be read as one (`//`, `http://[`). */
function requestUrl(request: IncomingMessage): URL | undefined {
	try {
		return new URL(request.url ?? "/", "http://localhost");
	} catch {
		return undefined;
	}
}

/** CORS for the API: the response names the asking origin; a preflight is answered here (true) */
function allowCrossOrigin(request: IncomingMessage, response: ServerResponse): boolean {
	const origin = request.headers.origin;
	if (origin === undefined) return false;
	response.setHeader("Access-Control-Allow-Origin", origin);
	response.setHeader("Vary", "Origin");
	response.setHeader("Access-Control-Expose-Headers", "Content-Disposition, Content-Range, Content-Length, Accept-Ranges");
	if (request.method !== "OPTIONS") return false;
	response.writeHead(204, {
		"Access-Control-Allow-Methods": "GET, HEAD, POST, PUT",
		"Access-Control-Allow-Headers": "Authorization, Content-Type, Range",
		"Access-Control-Max-Age": "600",
	});
	response.end();
	request.resume();
	return true;
}

function fail(request: IncomingMessage, response: ServerResponse, status: number, code: string, message: string): void {
	if (!response.headersSent) {
		response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
		response.end(JSON.stringify({ error: { code, message } }));
	} else {
		response.destroy();
	}
	request.resume();
}

function failed(request: IncomingMessage, response: ServerResponse, error: unknown): void {
	console.error(`${request.method} ${request.url} failed: ${error instanceof Error ? error.stack : String(error)}`);
	fail(request, response, 500, "internal", "The server failed");
}

function authorized(request: IncomingMessage, token: string | undefined): boolean {
	if (token === undefined) return true;
	const header = request.headers.authorization;
	const url = requestUrl(request);
	const offered = (request.headers["sec-websocket-protocol"] ?? "").split(",").map((each) => each.trim());
	const inProtocol = offered.find((each) => each.startsWith(TOKEN_PROTOCOL));
	const given = header?.startsWith("Bearer ")
		? header.slice(7)
		: inProtocol !== undefined
			? Buffer.from(inProtocol.slice(TOKEN_PROTOCOL.length), "base64url").toString()
			: url?.searchParams.get("token");
	if (given === null || given === undefined) return false;
	const a = Buffer.from(given);
	const b = Buffer.from(token);
	return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * The search index beside a database, made again when the database is not the one it was built from (a new file at
 * the same path): its rows would point at conversations that are gone, or at others under their IDs. The database's
 * inode, kept beside the index, tells.
 */
function searchIndexPath(database: string): string {
	const path = `${database.replace(/\.db$/, "")}.search.db`;
	const marker = `${path}.source`;
	const source = existsSync(database) ? String(statSync(database).ino) : "";
	if (existsSync(path) && (!existsSync(marker) || readFileSync(marker, "utf8") !== source)) {
		for (const suffix of ["", "-wal", "-shm"]) rmSync(`${path}${suffix}`, { force: true });
	}
	writeFileSync(marker, source);
	return path;
}
