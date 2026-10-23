// Images in entries, sent by reference. A photo the user sent or an image a tool returned (the read tool's) is kept in
// its entry as base64, up to 4.5 MB; clients get each one as
// `{ type: "image", mimeType, media: { entryId, index, bytes, width, height } }` instead, and fetch the data with
// `media.get` when it shows it. History then syncs in kilobytes, and a phone decodes only what is on screen.
// See docs/media.md.
import type { EntryRecord } from "@earendil-works/pi-durable";

/** What a client needs to show an image before it has it: where to get it, how big it is, its shape. */
export type MediaRef = { entryId: number; index: number; bytes: number; width?: number; height?: number };

/** Formats a client shows: the ones every provider takes. */
const IMAGE_TYPES: ReadonlySet<string> = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
/** Base64 decoded for a header: a JPEG's SOF can follow an EXIF block of tens of kilobytes. */
const HEADER_CHARS = 128 * 1024;

type ImageBlock = { type: "image"; data: string; mimeType: string };

function isImage(block: unknown): block is ImageBlock {
	const candidate = block as Partial<ImageBlock> | null;
	return candidate?.type === "image" && typeof candidate.data === "string" && typeof candidate.mimeType === "string";
}

/** Each image block of an entry's messages, in order: their content arrays, messages first to last. */
export function entryImages(entry: EntryRecord): ImageBlock[] {
	const images: ImageBlock[] = [];
	for (const message of entry.model ?? []) {
		if (typeof message.content === "string") continue;
		for (const block of message.content as readonly unknown[]) if (isImage(block)) images.push(block);
	}
	return images;
}

/** `entry` with each image's data replaced by its reference; the entry itself when it has none. */
export function withMediaRefs(entry: EntryRecord): EntryRecord {
	if (entryImages(entry).length === 0) return entry;
	let index = 0;
	const model = (entry.model ?? []).map((message) => {
		if (typeof message.content === "string") return message;
		const content = (message.content as readonly unknown[]).map((block) => {
			if (!isImage(block)) return block;
			const media: MediaRef = { entryId: entry.id, index: index++, bytes: Math.floor((block.data.length * 3) / 4) };
			const size = IMAGE_TYPES.has(block.mimeType) ? imageDimensions(Buffer.from(block.data.slice(0, HEADER_CHARS), "base64"), block.mimeType) : undefined;
			if (size !== undefined) {
				media.width = size.width;
				media.height = size.height;
			}
			return { type: "image", mimeType: block.mimeType, media };
		});
		return { ...message, content };
	});
	return { ...entry, model } as unknown as EntryRecord;
}

/**
 * The width and height an image declares in its header, without decoding it: PNG's IHDR, GIF's screen, WebP's VP8,
 * VP8L or VP8X chunk, JPEG's first SOF segment. Copied from pi-durable's tools/image.ts, which does not export it.
 */
export function imageDimensions(bytes: Uint8Array, mimeType: string): { width: number; height: number } | undefined {
	const u16le = (offset: number) => (bytes[offset] ?? 0) + ((bytes[offset + 1] ?? 0) << 8);
	const u16be = (offset: number) => ((bytes[offset] ?? 0) << 8) + (bytes[offset + 1] ?? 0);
	const u32be = (offset: number) => (bytes[offset] ?? 0) * 0x1000000 + ((bytes[offset + 1] ?? 0) << 16) + ((bytes[offset + 2] ?? 0) << 8) + (bytes[offset + 3] ?? 0);
	const u32le = (offset: number) => u16le(offset) + u16le(offset + 2) * 0x10000;
	const ascii = (offset: number, text: string) => [...text].every((character, index) => bytes[offset + index] === character.charCodeAt(0));
	switch (mimeType) {
		case "image/png":
			return bytes.length < 24 ? undefined : { width: u32be(16), height: u32be(20) };
		case "image/gif":
			return bytes.length < 10 ? undefined : { width: u16le(6), height: u16le(8) };
		case "image/webp":
			if (bytes.length < 30) return undefined;
			if (ascii(12, "VP8 ")) return { width: u16le(26) & 0x3fff, height: u16le(28) & 0x3fff };
			if (ascii(12, "VP8L")) {
				const bits = u32le(21);
				return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
			}
			if (ascii(12, "VP8X")) return { width: u16le(24) + ((bytes[26] ?? 0) << 16) + 1, height: u16le(27) + ((bytes[29] ?? 0) << 16) + 1 };
			return undefined;
		case "image/jpeg":
			for (let offset = 2; offset + 9 <= bytes.length; ) {
				if (bytes[offset] !== 0xff) return undefined;
				const marker = bytes[offset + 1]!;
				if (marker === 0xff) {
					offset++;
					continue;
				}
				// SOF0 to SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
				if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) return { width: u16be(offset + 7), height: u16be(offset + 5) };
				offset += 2 + u16be(offset + 2);
			}
			return undefined;
		default:
			return undefined;
	}
}
