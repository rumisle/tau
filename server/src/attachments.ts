// How a message's files reach the model: its first text block names each by path (docs/files.md), in pi's
// `<file name="…">` form, the way `pi @file` attaches one:
//
//   <attachments>
//   <image name="/…/tau.files/7f3a…/IMG_2041.jpg" type="image/jpeg" bytes="812044" width="2000" height="1500"/>
//   <file name="/…/tau.files/a81c…/report.pdf" type="application/pdf" bytes="1204331"/>
//   </attachments>
//
// An `<image>` is also in the message as an image block, after this one, in the same order; a `<file>` is only named,
// for the model to read or run whatever it likes on. Clients show the files and not this block; the chat list, search
// and titles read the text without it.
import type { ImageContent, TextContent } from "@earendil-works/pi-ai";
import type { StoredFile } from "./files.ts";

const OPEN = "<attachments>\n";
const CLOSE = "\n</attachments>";
const LINE = /^<(image|file) name="([^"]*)" type="([^"]*)" bytes="(\d+)"(?: width="(\d+)" height="(\d+)")?\/>$/;

export type AttachmentLine = {
	kind: "image" | "file";
	path: string;
	mimeType: string;
	bytes: number;
	width?: number;
	height?: number;
};

/** The block naming `files`; `shown` ones are images the message also carries. */
export function attachmentsText(files: readonly { file: StoredFile; shown: boolean }[]): string {
	const lines = files.map(({ file, shown }) => {
		const size = file.width !== undefined && file.height !== undefined ? ` width="${file.width}" height="${file.height}"` : "";
		return `<${shown ? "image" : "file"} name="${escape(file.path)}" type="${escape(file.mimeType)}" bytes="${file.bytes}"${size}/>`;
	});
	return `${OPEN}${lines.join("\n")}${CLOSE}`;
}

/** The files a block names, when it is exactly such a block; undefined for any other text. */
export function parseAttachments(text: string): AttachmentLine[] | undefined {
	if (!text.startsWith(OPEN) || !text.endsWith(CLOSE)) return undefined;
	const body = text.slice(OPEN.length, text.length - CLOSE.length);
	const lines: AttachmentLine[] = [];
	for (const line of body.split("\n")) {
		const match = LINE.exec(line);
		if (match === null) return undefined;
		const [, kind, path, type, bytes, width, height] = match;
		lines.push({
			kind: kind as AttachmentLine["kind"],
			path: unescape(path!),
			mimeType: unescape(type!),
			bytes: Number(bytes),
			...(width === undefined ? {} : { width: Number(width), height: Number(height) }),
		});
	}
	return lines.length === 0 ? undefined : lines;
}

/** A user message's own text: its text blocks, less an attachments block. */
export function ownText(content: string | readonly (TextContent | ImageContent)[]): string {
	if (typeof content === "string") return content;
	return content
		.filter((part): part is TextContent => part.type === "text" && parseAttachments(part.text) === undefined)
		.map((part) => part.text)
		.join("\n");
}

/** The files an attachments block of `content` names; none without one. */
export function attachedFiles(content: string | readonly (TextContent | ImageContent)[]): AttachmentLine[] {
	if (typeof content === "string") return [];
	for (const part of content) {
		if (part.type !== "text") continue;
		const lines = parseAttachments(part.text);
		if (lines !== undefined) return lines;
	}
	return [];
}

function escape(value: string): string {
	return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/\n/g, "&#10;");
}

function unescape(value: string): string {
	return value.replace(/&#10;/g, "\n").replace(/&gt;/g, ">").replace(/&lt;/g, "<").replace(/&quot;/g, '"').replace(/&amp;/g, "&");
}
