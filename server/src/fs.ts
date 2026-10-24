// Paths from the command line: the directory chats start in.
import { stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { ProtocolError } from "./protocol.ts";

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
