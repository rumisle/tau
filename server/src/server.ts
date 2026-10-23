// WebSocket transport: one Connection per socket, optional bearer token.
import { timingSafeEqual } from "node:crypto";
import { existsSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import { Connection } from "./connection.ts";
import { Dialogs } from "./dialogs.ts";
import type { Host } from "./host.ts";
import { Notifier, type PushSender } from "./notifier.ts";
import { Search } from "./search/service.ts";
import { Titler } from "./titles.ts";

export type ServerOptions = {
	host?: string;
	port?: number;
	/** Required as `Authorization: Bearer <token>` or `?token=<token>` when set. */
	token?: string;
	/** Apple's push service, with the account's key (src/apns.ts); without it, pushes go through ntfy only. */
	apns?: PushSender;
	/** For tests: how long an activity whose chats are all done stays (half an hour). */
	activityDoneLifetimeMs?: number;
};

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
	const connections = new Set<Connection>();
	const wss = new WebSocketServer({
		host: options.host ?? "127.0.0.1",
		port: options.port ?? 0,
		perMessageDeflate: { threshold: 1024 },
		// Above the content limits of conversation.submit, so too much content is refused with `too_large` instead
		// of closing the socket, which the client would take for a network failure and retry forever.
		maxPayload: 96 * 1024 * 1024,
		verifyClient: ({ req }: { req: IncomingMessage }) => authorized(req, options.token),
	});
	wss.on("connection", (socket) => {
		const connection = new Connection(host, dialogs, socket, notifier, search);
		connections.add(connection);
		// Frames are handled concurrently; responses carry request IDs.
		socket.on("message", (data, isBinary) => {
			if (isBinary) socket.close(1003, "text frames only");
			else void connection.receive(data.toString());
		});
		socket.on("close", () => {
			connections.delete(connection);
			void connection.close();
		});
		socket.on("error", () => socket.close());
	});
	await new Promise<void>((resolve, reject) => {
		wss.once("listening", resolve);
		wss.once("error", reject);
	});
	const address = wss.address() as AddressInfo;
	return {
		url: `ws://${address.address.includes(":") ? `[${address.address}]` : address.address}:${address.port}`,
		notifier,
		close: async () => {
			for (const client of wss.clients) client.terminate();
			await Promise.allSettled([...connections].map((connection) => connection.close()));
			dialogs.close();
			titler.close();
			notifier.close();
			search.close();
			await new Promise<void>((resolve) => wss.close(() => resolve()));
		},
	};
}

function authorized(request: IncomingMessage, token: string | undefined): boolean {
	if (token === undefined) return true;
	const header = request.headers.authorization;
	const url = new URL(request.url ?? "/", "http://localhost");
	const given = header?.startsWith("Bearer ") ? header.slice(7) : url.searchParams.get("token");
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
