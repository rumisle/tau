// Files over HTTP, on the WebSocket's port and behind its token (docs/files.md): uploads stream to disk, and a kept
// file is fetched as it is, in ranges, so a large one resumes where it stopped.
//
//   POST /files?name=<name>   body: the bytes         -> 201 { id, name, mimeType, bytes, width?, height? }
//   GET  /files/<id>          (HEAD, Range)            -> the file
import { createReadStream } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { FileError, type FileStore, type StoredFile } from "./files.ts";

export async function handleFiles(store: FileStore, request: IncomingMessage, response: ServerResponse): Promise<void> {
	const url = new URL(request.url ?? "/", "http://localhost");
	try {
		if (url.pathname === "/files" && (request.method === "POST" || request.method === "PUT")) {
			const declared = request.headers["content-length"] === undefined ? undefined : Number(request.headers["content-length"]);
			const file = await store.upload(url.searchParams.get("name") ?? "file", request, Number.isFinite(declared) ? declared : undefined);
			send(response, 201, publicFile(file));
			return;
		}
		const match = /^\/files\/([0-9a-f]{32})$/.exec(url.pathname);
		if (match !== null && (request.method === "GET" || request.method === "HEAD")) {
			const file = await store.get(match[1]!);
			if (file === undefined) return send(response, 404, { error: { code: "not_found", message: "No such file" } });
			serveFile(file, request, response);
			return;
		}
		send(response, 404, { error: { code: "not_found", message: "Not found" } });
	} catch (error) {
		const code = error instanceof FileError ? error.code : "internal";
		const status = code === "too_large" ? 413 : code === "not_found" ? 404 : code === "bad_request" ? 400 : 500;
		if (!response.headersSent) send(response, status, { error: { code, message: error instanceof Error ? error.message : String(error) } });
		else response.destroy();
		// The rest of a refused upload is not read.
		if (status === 413) request.destroy();
	}
}

function publicFile(file: StoredFile): Omit<StoredFile, "path"> {
	const { path: _path, ...rest } = file;
	return rest;
}

function serveFile(file: StoredFile, request: IncomingMessage, response: ServerResponse): void {
	const headers: Record<string, string> = {
		"Content-Type": file.mimeType,
		"Accept-Ranges": "bytes",
		// Kept files never change.
		"Cache-Control": "private, max-age=31536000, immutable",
		ETag: `"${file.id}"`,
		"Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(file.name)}`,
		"X-Content-Type-Options": "nosniff",
	};
	let start = 0;
	let end = file.bytes - 1;
	let status = 200;
	const range = request.headers.range;
	if (range !== undefined) {
		const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
		const first = match?.[1] ?? "";
		const last = match?.[2] ?? "";
		if (match !== null && (first !== "" || last !== "")) {
			if (first === "") start = Math.max(0, file.bytes - Number(last));
			else {
				start = Number(first);
				if (last !== "") end = Math.min(end, Number(last));
			}
			if (start > end || start >= file.bytes) {
				response.writeHead(416, { "Content-Range": `bytes */${file.bytes}` });
				response.end();
				return;
			}
			status = 206;
			headers["Content-Range"] = `bytes ${start}-${end}/${file.bytes}`;
		}
	}
	headers["Content-Length"] = String(file.bytes === 0 ? 0 : end - start + 1);
	response.writeHead(status, headers);
	if (request.method === "HEAD" || file.bytes === 0) {
		response.end();
		return;
	}
	const stream = createReadStream(file.path, { start, end });
	stream.on("error", () => response.destroy());
	stream.pipe(response);
}

function send(response: ServerResponse, status: number, body: unknown): void {
	const text = JSON.stringify(body);
	response.writeHead(status, { "Content-Type": "application/json", "Content-Length": String(Buffer.byteLength(text)) });
	response.end(text);
}
