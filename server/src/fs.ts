// The server's file system as the client sees it: browsing directories to pick a conversation's working directory.
import type { Dirent } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { ProtocolError } from "./protocol.ts";

const MAX_ENTRIES = 2_000;

export type DirEntry = { name: string; kind: "dir" | "file" | "link" | "other"; git?: true };
export type DirListing = { path: string; parent?: string; entries: DirEntry[]; truncated?: true };

/** An absolute path from client input: `~` expands to the home directory; relative paths are rejected. */
export function absolute(path: string): string {
	if (path === "~") return homedir();
	if (path.startsWith("~/")) return join(homedir(), path.slice(2));
	if (!isAbsolute(path)) throw new ProtocolError("bad_request", `Path must be absolute or start with ~: ${path}`);
	return resolve(path);
}

/** `path` as an absolute existing directory, or a bad_request error. */
export async function directory(path: string): Promise<string> {
	const resolved = absolute(path);
	const info = await stat(resolved).catch(() => undefined);
	if (info === undefined) throw new ProtocolError("bad_request", `No such directory: ${resolved}`);
	if (!info.isDirectory()) throw new ProtocolError("bad_request", `Not a directory: ${resolved}`);
	return resolved;
}

/** One directory's entries: directories first, then by name. Dotfiles only with `hidden`. */
export async function listDirectory(path: string, options: { hidden?: boolean } = {}): Promise<DirListing> {
	const resolved = await directory(path);
	let dirents: Dirent[];
	try {
		dirents = await readdir(resolved, { withFileTypes: true });
	} catch (error) {
		throw new ProtocolError("bad_request", `Cannot read ${resolved}: ${(error as Error).message}`);
	}
	const visible = dirents.filter((dirent) => options.hidden || !dirent.name.startsWith("."));
	const entries = await Promise.all(
		visible.slice(0, MAX_ENTRIES).map(async (dirent): Promise<DirEntry> => {
			let kind: DirEntry["kind"] = dirent.isDirectory()
				? "dir"
				: dirent.isFile()
					? "file"
					: dirent.isSymbolicLink()
						? "link"
						: "other";
			// A link to a directory can be entered like one.
			if (kind === "link" && (await stat(join(resolved, dirent.name)).catch(() => undefined))?.isDirectory()) kind = "dir";
			if (kind !== "dir") return { name: dirent.name, kind };
			const git = await stat(join(resolved, dirent.name, ".git")).catch(() => undefined);
			return git === undefined ? { name: dirent.name, kind } : { name: dirent.name, kind, git: true };
		}),
	);
	entries.sort((a, b) => Number(b.kind === "dir") - Number(a.kind === "dir") || a.name.localeCompare(b.name));
	const parent = dirname(resolved);
	return {
		path: resolved,
		...(parent === resolved ? {} : { parent }),
		entries,
		...(visible.length > MAX_ENTRIES ? { truncated: true as const } : {}),
	};
}
