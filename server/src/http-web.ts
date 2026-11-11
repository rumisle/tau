// The web app, served on the server's port (docs/web.md "Serving and connecting"): the built files of web/ as they
// are, without a token (the app holds no data; it asks for the token itself), `index.html` for any other path the app
// routes itself. Hashed assets are cached for good, the rest revalidated.
import { createReadStream, existsSync, statSync } from "node:fs";
import { type IncomingMessage, request as httpRequest, type ServerResponse } from "node:http";
import { extname, join, normalize, resolve, sep } from "node:path";

const TYPES: Record<string, string> = {
	".html": "text/html; charset=utf-8",
	".js": "text/javascript; charset=utf-8",
	".mjs": "text/javascript; charset=utf-8",
	".css": "text/css; charset=utf-8",
	".json": "application/json",
	".webmanifest": "application/manifest+json",
	".svg": "image/svg+xml",
	".png": "image/png",
	".jpg": "image/jpeg",
	".webp": "image/webp",
	".ico": "image/x-icon",
	".woff": "font/woff",
	".woff2": "font/woff2",
	".wasm": "application/wasm",
	".mp3": "audio/mpeg",
	".mp4": "video/mp4",
	".tgs": "application/x-tgsticker",
	".txt": "text/plain; charset=utf-8",
	".xml": "application/xml",
};

// Vite names built assets by their content: `index-B4x9Qf2a.js`
const HASHED = /-[\w-]{8}\.\w+$/;

export class WebApp {
	readonly dir: string;

	constructor(dir: string) {
		this.dir = resolve(dir);
	}

	/** A built app is in `dir`. */
	static at(dir: string): WebApp | undefined {
		return existsSync(join(dir, "index.html")) ? new WebApp(dir) : undefined;
	}

	/**
	 * Serves a GET or HEAD for the app; false for anything else, which the server handles. Whatever the request's path
	 * holds, it answers or declines, and never throws: a path it cannot decode is a 400.
	 */
	handle(request: IncomingMessage, response: ServerResponse): boolean {
		if (request.method !== "GET" && request.method !== "HEAD") return false;
		let path: string;
		try {
			path = decodeURIComponent(new URL(request.url ?? "/", "http://localhost").pathname);
		} catch {
			return answer(response, 400, "Bad request");
		}
		// A NUL makes the file system calls throw
		if (path.includes("\0")) return answer(response, 400, "Bad request");
		let file = normalize(join(this.dir, path));
		if (file !== this.dir && !file.startsWith(this.dir + sep)) return false;
		if (!isFile(file)) {
			// A path the app routes (or a file it does not have, which then says so itself)
			if (extname(path) !== "") return answer(response, 404, "Not found");
			file = join(this.dir, "index.html");
		}
		let size: number;
		try {
			size = statSync(file).size;
		} catch {
			// Gone between the two looks (a new build replacing this one)
			return answer(response, 404, "Not found");
		}
		response.writeHead(200, {
			"Content-Type": TYPES[extname(file)] ?? "application/octet-stream",
			"Content-Length": size,
			"Cache-Control": HASHED.test(file) ? "public, max-age=31536000, immutable" : "no-cache",
			"X-Content-Type-Options": "nosniff",
			"Referrer-Policy": "no-referrer",
			// Web A's index.html has its Content-Security-Policy (web/vite.config.ts buildCsp)
		});
		if (request.method === "HEAD") response.end();
		else createReadStream(file).on("error", () => response.destroy()).pipe(response);
		return true;
	}
}

function isFile(path: string): boolean {
	try {
		return statSync(path).isFile();
	} catch {
		return false;
	}
}

function answer(response: ServerResponse, status: number, text: string): true {
	response.writeHead(status, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
	response.end(text);
	return true;
}

/**
 * The web app from Vite's dev server instead of a build (`--web-dev <url>`, for scripts/web/test.sh e2e --dev): every
 * request for the app is passed to it as it is, so an edit is in the next page load, while the socket, /auth and /files
 * stay this server's, same-origin as with a build.
 */
export class WebDevProxy {
	readonly dir: string;
	readonly #target: URL;

	constructor(url: string) {
		this.#target = new URL(url);
		this.dir = this.#target.origin;
	}

	handle(request: IncomingMessage, response: ServerResponse): boolean {
		if (request.method !== "GET" && request.method !== "HEAD") return false;
		const upstream = httpRequest(
			{
				host: this.#target.hostname,
				port: this.#target.port,
				method: request.method,
				path: request.url,
				headers: { ...request.headers, host: this.#target.host },
			},
			(answered) => {
				response.writeHead(answered.statusCode ?? 502, answered.headers);
				answered.pipe(response);
			},
		);
		upstream.on("error", () => {
			if (!response.headersSent) answer(response, 502, `No dev server at ${this.dir}`);
			else response.destroy();
		});
		request.pipe(upstream);
		return true;
	}
}
