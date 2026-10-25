// What a message quotes from the chat (docs/quotes.md): `<tau:quote>` around the words, on lines of their own for a
// block, in a line for a few words; inside code (a fence, a backtick span) a tag is code, and one never closed is text.
// The app's ios/Tau/Common/TauQuote.swift reads them the same way.

const OPEN = "<tau:quote>";
const CLOSE = "</tau:quote>";

type Piece = { kind: "text" | "block" | "inline"; text: string };

function fenceMarker(trimmed: string): string | undefined {
	if (trimmed.startsWith("```")) return "```";
	if (trimmed.startsWith("~~~")) return "~~~";
	return undefined;
}

function unescape(text: string): string {
	return text.replaceAll("&lt;/tau:quote>", CLOSE);
}

function blockEnd(lines: string[], start: number): number | undefined {
	let fence: string | undefined;
	for (let index = start; index < lines.length; index++) {
		const trimmed = lines[index]!.trim();
		if (fence !== undefined) {
			if (trimmed.startsWith(fence)) fence = undefined;
		} else if (fenceMarker(trimmed) !== undefined) {
			fence = fenceMarker(trimmed);
		} else if (trimmed === CLOSE) {
			return index;
		}
	}
	return undefined;
}

function inlinePieces(line: string): Piece[] {
	if (!line.includes(OPEN)) return [{ kind: "text", text: line }];
	const pieces: Piece[] = [];
	let text = "";
	let inCode = false;
	let index = 0;
	while (index < line.length) {
		if (!inCode && line.startsWith(OPEN, index)) {
			const end = line.indexOf(CLOSE, index + OPEN.length);
			const value = end < 0 ? "" : line.slice(index + OPEN.length, end);
			if (end >= 0 && !value.includes("`")) {
				if (text !== "") pieces.push({ kind: "text", text });
				text = "";
				pieces.push({ kind: "inline", text: unescape(value) });
				index = end + CLOSE.length;
				continue;
			}
		}
		const character = line[index]!;
		if (character === "`") inCode = !inCode;
		text += character;
		index++;
	}
	if (text !== "") pieces.push({ kind: "text", text });
	return pieces;
}

function parse(text: string): Piece[] {
	if (!text.includes(OPEN)) return [{ kind: "text", text }];
	const pieces: Piece[] = [];
	let pending = "";
	const flush = () => {
		if (pending !== "") pieces.push({ kind: "text", text: pending });
		pending = "";
	};
	const lines = text.split("\n");
	let fence: string | undefined;
	for (let index = 0; index < lines.length; index++) {
		const line = lines[index]!;
		const trimmed = line.trim();
		const newline = index === lines.length - 1 ? "" : "\n";
		if (fence !== undefined) {
			if (trimmed.startsWith(fence)) fence = undefined;
			pending += line + newline;
			continue;
		}
		const marker = fenceMarker(trimmed);
		if (marker !== undefined) {
			fence = marker;
			pending += line + newline;
			continue;
		}
		const end = trimmed === OPEN ? blockEnd(lines, index + 1) : undefined;
		if (end !== undefined) {
			flush();
			pieces.push({ kind: "block", text: unescape(lines.slice(index + 1, end).join("\n")) });
			if (end < lines.length - 1) pending = "\n";
			index = end;
			continue;
		}
		for (const piece of inlinePieces(line)) {
			if (piece.kind === "text") {
				pending += piece.text;
			} else {
				flush();
				pieces.push(piece);
			}
		}
		pending += newline;
	}
	flush();
	return pieces;
}

/** For a one-line preview: the message's own words, a block left out (unless it is all there is), a few quoted words as they are. */
export function withoutQuotes(text: string): string {
	const pieces = parse(text);
	if (pieces.every((piece) => piece.kind === "text")) return text;
	const own = pieces.filter((piece) => piece.kind !== "block").map((piece) => piece.text).join("");
	const quoted = pieces.filter((piece) => piece.kind === "block").map((piece) => piece.text).join("\n");
	return own.trim() === "" ? quoted : own;
}
