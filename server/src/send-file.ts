// The model sends files to the user: `send_file` copies each into the file store (src/files.ts) as it is now, and the
// apps show them where the call is in the answer, images as photos and the rest as files to open, share or save.
// See docs/files.md.
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import type { Context } from "@earendil-works/chord";
import { Type } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { callFileId, FileError, type FileStore, formatBytes, type StoredFile } from "./files.ts";

const MAX_FILES = 10;

/** What a call's result carries for the apps: the files, by ID, as the store keeps them. */
export type SentFile = { id: string; name: string; mimeType: string; bytes: number; width?: number; height?: number };

export function sendFileExtension(store: FileStore): Extension {
	const tool = defineTool({
		name: "send_file",
		description:
			"Send files to the user, who sees them in the chat: images as photos, anything else as a file to open, share " +
			`or save. paths: up to ${MAX_FILES} files, absolute or relative to the working directory. Each is copied as it ` +
			"is now, so later changes do not reach the user; a directory cannot be sent (archive it first). Send what the " +
			"user asked for or should see, such as a chart, a report or a build; the user's own attachments are theirs already.",
		parameters: Type.Object({
			paths: Type.Array(Type.String({ description: "A file to send" }), { minItems: 1, maxItems: MAX_FILES }),
		}),
		// Each file's copy is named by the call, so a run again finds the one made and makes no other.
		replay: "safe",
		execute: async (args, api, context: Context) => {
			const cwd = api.env?.cwd ?? homedir();
			const sent: SentFile[] = [];
			const problems: string[] = [];
			const paths = args.paths.slice(0, MAX_FILES);
			for (const [index, given] of paths.entries()) {
				const source = resolvePath(given, cwd);
				try {
					const file = await store.adopt(source, callFileId(api.conversationId, api.callId, index));
					sent.push(sentFile(file));
				} catch (error) {
					problems.push(`${given}: ${error instanceof FileError || error instanceof Error ? error.message : String(error)}`);
				}
			}
			const lines: string[] = [];
			if (sent.length > 0) lines.push(`Sent to the user: ${sent.map((file) => `${file.name} (${formatBytes(file.bytes)})`).join(", ")}.`);
			if (problems.length > 0) lines.push(`Not sent:\n${problems.join("\n")}`);
			return {
				output: [{ type: "text" as const, text: lines.join("\n") }],
				...(sent.length === 0 ? { isError: true } : {}),
				details: { files: sent },
			};
		},
	});
	return defineExtension({ name: "send-file", tools: [tool] });
}

function sentFile(file: StoredFile): SentFile {
	return {
		id: file.id,
		name: file.name,
		mimeType: file.mimeType,
		bytes: file.bytes,
		...(file.width === undefined ? {} : { width: file.width, height: file.height! }),
	};
}

function resolvePath(path: string, cwd: string): string {
	const trimmed = path.trim().replace(/^@/, "");
	if (trimmed === "~") return homedir();
	if (trimmed.startsWith("~/")) return join(homedir(), trimmed.slice(2));
	return isAbsolute(trimmed) ? trimmed : resolve(cwd, trimmed);
}
