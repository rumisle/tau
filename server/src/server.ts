// WebSocket transport: one Connection per socket, optional bearer token.
import { timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer } from "ws";
import { Connection } from "./connection.ts";
import { Dialogs } from "./dialogs.ts";
import type { Host } from "./host.ts";

export type ServerOptions = {
	host?: string;
	port?: number;
	/** Required as `Authorization: Bearer <token>` or `?token=<token>` when set. */
	token?: string;
};

export type Server = {
	readonly url: string;
	close(): Promise<void>;
};

export async function serve(host: Host, options: ServerOptions = {}): Promise<Server> {
	const dialogs = new Dialogs(host);
	const connections = new Set<Connection>();
	const wss = new WebSocketServer({
		host: options.host ?? "127.0.0.1",
		port: options.port ?? 0,
		perMessageDeflate: { threshold: 1024 },
		maxPayload: 32 * 1024 * 1024,
		verifyClient: ({ req }: { req: IncomingMessage }) => authorized(req, options.token),
	});
	wss.on("connection", (socket) => {
		const connection = new Connection(host, dialogs, socket);
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
		close: async () => {
			for (const client of wss.clients) client.terminate();
			await Promise.allSettled([...connections].map((connection) => connection.close()));
			dialogs.close();
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
