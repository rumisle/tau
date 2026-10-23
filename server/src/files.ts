// Files the user sends and the model sends back, kept beside the database for as long as it is: a message refers to its
// files by path, and conversations are never deleted (durable deletes none), so neither are the files a message refers
// to. See docs/files.md.
//
//   <root>/<id>/<name>      the file, read-only (0400) in a read-only directory (0500): a model's command cannot
//                           change or remove it by accident; it copies one to change it
//   <root>/.pending/<id>    an upload no entry refers to yet: empty, swept a day after it came (its message failed
//                           to send); "submitted", a week after its message was (withdrawn before it reached the
//                           model, or still queued)
//
// Before a pending file goes, the store asks whether an entry names it (`referenced`, the search index's record of
// what each entry names): one that does is kept for good, so a file a message refers to is never removed, whichever
// message it was uploaded for (an edit sends its message's files again by ID).
//
// The root only its owner may enter (0700), whatever the umask. IDs are 128 random bits, hex; a tool's file gets one
// derived from its call, so a call run again after a restart writes the same file.
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, constants, createWriteStream, mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { chmod, copyFile, mkdir, open, readdir, rename, rm, stat, unlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";
import type { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { imageDimensions } from "./media.ts";

/** A kept file: where it is, what it is called, and what it is. */
export type StoredFile = {
	id: string;
	name: string;
	path: string;
	bytes: number;
	mimeType: string;
	width?: number;
	height?: number;
};

export class FileError extends Error {
	readonly code: "not_found" | "too_large" | "bad_request";
	constructor(code: FileError["code"], message: string) {
		super(message);
		this.name = "FileError";
		this.code = code;
	}
}

const ID = /^[0-9a-f]{32}$/;
/** An upload no message took is swept after this long: long enough for an outbox that waits for the network. */
const PENDING_LIFETIME_MS = 24 * 60 * 60 * 1000;
/** One a message named, which no entry does: its message was withdrawn, or waits in the inbox, longer than any run. */
const SUBMITTED_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const SUBMITTED = "submitted";
/** Default largest file, uploaded or sent; `--max-file-size` sets another. */
export const DEFAULT_MAX_FILE_BYTES = 1024 * 1024 * 1024;

export class FileStore {
	readonly root: string;
	readonly maxBytes: number;
	readonly #temporary: boolean;
	#sweeper: ReturnType<typeof setInterval> | undefined;
	/** Whether an entry names the file (src/search/service.ts); until it is set, nothing is swept. */
	referenced: ((id: string) => Promise<boolean>) | undefined;

	/** Files under `root`, made if need be; without one, a temporary directory removed on close. */
	constructor(root?: string, options: { maxBytes?: number } = {}) {
		this.#temporary = root === undefined;
		this.root = root ?? mkdtempSync(join(tmpdir(), "tau-files-"));
		this.maxBytes = options.maxBytes ?? DEFAULT_MAX_FILE_BYTES;
		mkdirSync(join(this.root, ".pending"), { recursive: true, mode: 0o700 });
		void chmod(this.root, 0o700).catch(() => {});
		this.#sweeper = setInterval(() => void this.sweep().catch(() => {}), 60 * 60 * 1000);
		this.#sweeper.unref();
	}

	close(): void {
		if (this.#sweeper !== undefined) clearInterval(this.#sweeper);
		this.#sweeper = undefined;
		if (this.#temporary) removeTree(this.root);
	}

	/**
	 * Keep what `body` streams as a new file called `name`, pending until a message refers to it. Over `maxBytes` it is
	 * refused (`too_large`) and nothing stays.
	 */
	async upload(name: string, body: Readable, declaredBytes?: number): Promise<StoredFile> {
		if (declaredBytes !== undefined && declaredBytes > this.maxBytes) throw tooLarge(this.maxBytes);
		const id = randomBytes(16).toString("hex");
		const fileName = safeName(name);
		// Pending before anything is written: a crash leaves a sweepable upload, never one kept for good.
		await writeFile(this.#pending(id), "", { mode: 0o600 });
		const directory = join(this.root, id);
		await mkdir(directory, { mode: 0o700 });
		const partial = join(directory, `.${fileName}.partial`);
		try {
			let bytes = 0;
			const limit = this.maxBytes;
			body.on("data", (chunk: Buffer) => {
				bytes += chunk.length;
				if (bytes > limit) body.destroy(tooLarge(limit));
			});
			await pipeline(body, createWriteStream(partial, { mode: 0o600, flags: "wx" }));
			await sync(partial);
			await rename(partial, join(directory, fileName));
			await seal(directory, fileName);
		} catch (error) {
			await removeUpload(directory);
			await unlink(this.#pending(id)).catch(() => {});
			throw error;
		}
		return (await this.get(id))!;
	}

	/**
	 * A copy of the file at `source`, kept for good (a message, the tool's, refers to it at once) under `id`; a call
	 * run again finds its copy there. Directories, and files over `maxBytes`, are refused.
	 */
	async adopt(source: string, id: string): Promise<StoredFile> {
		if (!ID.test(id)) throw new FileError("bad_request", `Not a file ID: ${id}`);
		const existing = await this.get(id);
		if (existing !== undefined) return existing;
		const info = await stat(source).catch(() => undefined);
		if (info === undefined) throw new FileError("not_found", `No file at ${source}`);
		if (info.isDirectory()) throw new FileError("bad_request", `${source} is a directory: send an archive of it instead`);
		if (!info.isFile()) throw new FileError("bad_request", `${source} is not a regular file`);
		if (info.size > this.maxBytes) throw tooLarge(this.maxBytes);
		const fileName = safeName(basename(source));
		const directory = join(this.root, id);
		// A copy cut off by a crash: start again.
		await removeUpload(directory);
		await mkdir(directory, { mode: 0o700 });
		const partial = join(directory, `.${fileName}.partial`);
		try {
			// A clone where the file system makes one (APFS, btrfs): no time, no space.
			await copyFile(source, partial, constants.COPYFILE_FICLONE);
			await chmod(partial, 0o600);
			await sync(partial);
			await rename(partial, join(directory, fileName));
			await seal(directory, fileName);
		} catch (error) {
			await removeUpload(directory);
			throw error;
		}
		return (await this.get(id))!;
	}

	/** The file kept under `id`, or undefined (no such ID, or an upload still being written). */
	async get(id: string): Promise<StoredFile | undefined> {
		if (!ID.test(id)) return undefined;
		const directory = join(this.root, id);
		// The file alone, once written; its `.partial` while it is.
		const names = await readdir(directory).catch(() => [] as string[]);
		if (names.length !== 1 || isPartial(names[0]!)) return undefined;
		const name = names[0]!;
		const path = join(directory, name);
		const info = await stat(path).catch(() => undefined);
		if (info === undefined || !info.isFile()) return undefined;
		const mimeType = await mimeTypeOf(path, name);
		const file: StoredFile = { id, name, path, bytes: info.size, mimeType };
		if (mimeType.startsWith("image/")) {
			const size = imageDimensions(await head(path, 128 * 1024), mimeType);
			if (size !== undefined) {
				file.width = size.width;
				file.height = size.height;
			}
		}
		return file;
	}

	/**
	 * Uploads a message names, before it is admitted: they wait a week for an entry to name them, not a day. A file
	 * already kept (an edit's) stays so.
	 */
	async submitted(ids: readonly string[]): Promise<void> {
		for (const id of ids) {
			if (!ID.test(id)) continue;
			const marker = this.#pending(id);
			if ((await stat(marker).catch(() => undefined)) !== undefined) await writeFile(marker, SUBMITTED, { mode: 0o600 });
		}
	}

	/**
	 * Remove uploads pending past their time that no entry names, and what an interrupted one left; one an entry names
	 * is kept for good. `lifetimeMs` overrides both lifetimes (tests). Returns how many went.
	 */
	async sweep(lifetimeMs?: number, now = Date.now()): Promise<number> {
		let removed = 0;
		for (const id of await readdir(join(this.root, ".pending")).catch(() => [] as string[])) {
			const marker = this.#pending(id);
			const info = await stat(marker).catch(() => undefined);
			if (info === undefined) continue;
			const submitted = info.size > 0;
			if (now - info.mtimeMs < (lifetimeMs ?? (submitted ? SUBMITTED_LIFETIME_MS : PENDING_LIFETIME_MS))) continue;
			if (ID.test(id)) {
				// Nothing known of what entries name: nothing goes.
				if (this.referenced === undefined) continue;
				let named: boolean;
				try {
					named = await this.referenced(id);
				} catch {
					// Unknown: asked again next time.
					continue;
				}
				if (!named) {
					await removeUpload(join(this.root, id));
					removed++;
				}
			}
			await unlink(marker).catch(() => {});
		}
		return removed;
	}

	/** For tests: make an upload look `ageMs` old. */
	async age(id: string, ageMs: number): Promise<void> {
		const at = new Date(Date.now() - ageMs);
		await utimes(this.#pending(id), at, at);
	}

	#pending(id: string): string {
		return join(this.root, ".pending", id);
	}
}

/** A tool call's file ID: the same for the same call, so a call run again after a restart keeps one copy. */
export function callFileId(conversationId: number, callId: string, index: number): string {
	return createHash("sha256").update(`${conversationId}\0${callId}\0${index}`).digest("hex").slice(0, 32);
}

/** The ID in a kept file's path, or undefined. */
export function fileIdOf(store: FileStore, path: string): string | undefined {
	const prefix = store.root.endsWith("/") ? store.root : `${store.root}/`;
	if (!path.startsWith(prefix)) return undefined;
	const id = path.slice(prefix.length).split("/")[0] ?? "";
	return ID.test(id) ? id : undefined;
}

/**
 * A file name to keep: its last component, without control characters or slashes, at most 200 bytes with its
 * extension kept; "file" when nothing is left. Never a dot file's `.partial` twin.
 */
export function safeName(name: string): string {
	let cleaned = basename(name.replace(/\\/g, "/"))
		.replace(/[\u0000-\u001f\u007f/]/g, "")
		.trim();
	if (cleaned === "" || cleaned === "." || cleaned === "..") cleaned = "file";
	if (cleaned.endsWith(".partial")) cleaned = `${cleaned}_`;
	const extension = extname(cleaned).slice(0, 16);
	while (Buffer.byteLength(cleaned) > 200) {
		const stem = cleaned.slice(0, cleaned.length - extension.length);
		cleaned = `${[...stem].slice(0, -1).join("")}${extension}`;
	}
	return cleaned;
}

function isPartial(name: string): boolean {
	return name.startsWith(".") && name.endsWith(".partial");
}

function tooLarge(limit: number): FileError {
	return new FileError("too_large", `A file can be at most ${formatBytes(limit)}`);
}

export function formatBytes(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`;
	if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`;
	return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
}

async function seal(directory: string, fileName: string): Promise<void> {
	await chmod(join(directory, fileName), 0o400);
	await chmod(directory, 0o500);
}

async function sync(path: string): Promise<void> {
	const handle = await open(path, "r+");
	try {
		await handle.sync();
	} finally {
		await handle.close();
	}
}

/** Remove a kept file's directory, read-only as it is. */
async function removeUpload(directory: string): Promise<void> {
	await chmod(directory, 0o700).catch(() => {});
	await rm(directory, { recursive: true, force: true });
}

/** Remove a temporary store: its read-only directories first made writable. */
function removeTree(root: string): void {
	for (const id of (() => {
		try {
			return readdirSync(root);
		} catch {
			return [];
		}
	})()) {
		try {
			chmodSync(join(root, id), 0o700);
		} catch {}
	}
	rmSync(root, { recursive: true, force: true });
}

async function head(path: string, length: number): Promise<Uint8Array> {
	const handle = await open(path, "r");
	try {
		const buffer = Buffer.alloc(length);
		const { bytesRead } = await handle.read(buffer, 0, length, 0);
		return buffer.subarray(0, bytesRead);
	} finally {
		await handle.close();
	}
}

/** Images by their first bytes (an extension can lie, and photos come named "photo"); the rest by extension. */
async function mimeTypeOf(path: string, name: string): Promise<string> {
	const bytes = await head(path, 16);
	const starts = (...values: number[]) => values.every((value, index) => bytes[index] === value);
	if (starts(0x89, 0x50, 0x4e, 0x47)) return "image/png";
	if (starts(0xff, 0xd8, 0xff)) return "image/jpeg";
	if (starts(0x47, 0x49, 0x46, 0x38)) return "image/gif";
	if (starts(0x52, 0x49, 0x46, 0x46) && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return "image/webp";
	if (starts(0x25, 0x50, 0x44, 0x46)) return "application/pdf";
	return MIME_TYPES[extname(name).toLowerCase()] ?? "application/octet-stream";
}

const MIME_TYPES: Record<string, string> = {
	".heic": "image/heic",
	".heif": "image/heif",
	".svg": "image/svg+xml",
	".bmp": "image/bmp",
	".tif": "image/tiff",
	".tiff": "image/tiff",
	".txt": "text/plain",
	".md": "text/markdown",
	".csv": "text/csv",
	".tsv": "text/tab-separated-values",
	".json": "application/json",
	".html": "text/html",
	".htm": "text/html",
	".xml": "application/xml",
	".yaml": "application/yaml",
	".yml": "application/yaml",
	".log": "text/plain",
	".js": "text/javascript",
	".ts": "text/plain",
	".py": "text/x-python",
	".swift": "text/plain",
	".rs": "text/plain",
	".go": "text/plain",
	".c": "text/plain",
	".h": "text/plain",
	".sh": "text/x-shellscript",
	".zip": "application/zip",
	".gz": "application/gzip",
	".tar": "application/x-tar",
	".tgz": "application/gzip",
	".7z": "application/x-7z-compressed",
	".mp3": "audio/mpeg",
	".m4a": "audio/mp4",
	".wav": "audio/wav",
	".mp4": "video/mp4",
	".mov": "video/quicktime",
	".doc": "application/msword",
	".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
	".xls": "application/vnd.ms-excel",
	".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
	".ppt": "application/vnd.ms-powerpoint",
	".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
	".key": "application/x-iwork-keynote-sffkey",
	".pages": "application/x-iwork-pages-sffpages",
	".numbers": "application/x-iwork-numbers-sffnumbers",
	".epub": "application/epub+zip",
};
